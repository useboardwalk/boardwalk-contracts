// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IntegrationBase, MockERC20, MockPair, MockDEXFactory, LaunchFactory} from "./IntegrationBase.t.sol";
import {PresaleManager} from "src/core/PresaleManager.sol";
import {LPStaking} from "src/core/LPStaking.sol";
import {FeeDistributor} from "src/core/FeeDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title StakingRewardsFlowTest
/// @notice Integration tests for LP staking: vesting distribution, weekly fee epochs, zero-staker periods
///         Covers plan edge cases: #7, #8, #9, #24, #25, #28, #35
contract StakingRewardsFlowTest is IntegrationBase {
    address internal tokenAddr;
    LaunchFactory.LaunchInfo internal info;
    address internal pair;
    uint256 internal seedTime;

    function setUp() public override {
        super.setUp();

        // Use Advanced launch (30% presale → 40% vesting → 8% LP incentive allocation)
        // Express has 50/50 = no vesting allocation, so LP staking wouldn't earn vesting rewards
        tokenAddr = _createAdvancedLaunch();
        info = _getLaunchInfo(tokenAddr);

        // Warp past 24hr delay for Advanced path
        uint256 presaleStart = PresaleManager(info.presaleManager).presaleStart();
        vm.warp(presaleStart + 1);

        // Contribute above graduation threshold
        _contribute(info.presaleManager, alice, 15 ether);

        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);
        PresaleManager(info.presaleManager).seedLiquidity();

        seedTime = PresaleManager(info.presaleManager).liquiditySeedTime();
        pair = dexFactory.getPair(tokenAddr, address(weth));
    }

    // ============ Vesting Allocation Verification ============

    function test_VestingAllocation_MatchesExpected() public {
        // Advanced path with 30% presale:
        // presaleTokens = TOTAL_SUPPLY * 30% = 3B
        // liquidityTokens = TOTAL_SUPPLY * 30% = 3B
        // vestingTotal = TOTAL_SUPPLY - 3B - 3B = 4B
        // lpIncentive = vestingTotal * 20% = 800M
        uint256 expectedLPIncentive = TOTAL_SUPPLY * 4000 / 10000 * 20 / 100; // 4B * 20% = 800M
        uint256 actualAllocation = LPStaking(info.lpStaking).vestingAllocation();
        assertEq(actualAllocation, expectedLPIncentive, "LP incentive vesting allocation mismatch");
    }

    function test_VestingRate_MatchesAllocation() public {
        uint256 vestingDuration = 3 * 365 days;
        uint256 expectedRate = LPStaking(info.lpStaking).vestingAllocation() / vestingDuration;
        uint256 actualRate = LPStaking(info.lpStaking).baseVestingRate();
        assertEq(actualRate, expectedRate, "Vesting rate should equal allocation / duration");
    }

    // ============ Edge Case #9: Single Staker Gets All Rewards ============

    function test_SingleStaker_GetsAllVestingRewards() public {
        // Get some LP tokens for alice
        uint256 lpBalance = IERC20(pair).balanceOf(address(0x000000000000000000000000000000000000dEaD));
        // We need LP tokens - mint some to alice for testing
        MockPair(pair).mint(alice, 1000e18);

        // Warp past vesting start (24h delay)
        vm.warp(seedTime + 24 hours + 1);

        // Alice stakes
        vm.startPrank(alice);
        IERC20(pair).approve(info.lpStaking, 1000e18);
        LPStaking(info.lpStaking).stake(1000e18);
        vm.stopPrank();

        // Warp forward 7 days (vesting distributes)
        vm.warp(block.timestamp + 7 days);

        // Check pending rewards match expected magnitude
        uint256 pending = LPStaking(info.lpStaking).pendingRewards(alice);
        assertGt(pending, 0, "Single staker should have pending vesting rewards");
        // Verify magnitude: baseVestingRate * 7 days should approximate pending
        uint256 expectedVesting = LPStaking(info.lpStaking).baseVestingRate() * 7 days;
        assertApproxEqRel(pending, expectedVesting, 0.01e18, "Pending should match 7 days of vesting rate");

        // Claim
        vm.prank(alice);
        uint256 claimed = LPStaking(info.lpStaking).claim();
        assertEq(claimed, pending, "Claimed should match pending");
        assertEq(IERC20(tokenAddr).balanceOf(alice), claimed, "Alice should receive claimed tokens");
    }

    // ============ Edge Case #7: Fee Distribution with Zero LP Stakers ============

    function test_ZeroStakers_FeesLost() public {
        // No one stakes. Warp past vesting start.
        vm.warp(seedTime + 24 hours + 1);

        uint256 accBefore = LPStaking(info.lpStaking).accRewardPerWeight();

        // Warp 7 days (vesting should distribute but no stakers → lost)
        vm.warp(block.timestamp + 7 days);

        // Trigger _updateAllRewards via stake (epochs advance lazily on stake/withdraw/claim)
        MockPair(pair).mint(alice, 1000e18);
        vm.startPrank(alice);
        IERC20(pair).approve(info.lpStaking, 1000e18);
        LPStaking(info.lpStaking).stake(1000e18);
        vm.stopPrank();

        // accRewardPerWeight should still be 0 (rewards lost during zero-staker period)
        uint256 accAfter = LPStaking(info.lpStaking).accRewardPerWeight();
        assertEq(accBefore, accAfter, "Rewards should be lost when no stakers");
        // Alice should have 0 pending (she just staked, past rewards were lost)
        assertEq(LPStaking(info.lpStaking).pendingRewards(alice), 0, "No pending after joining");
    }

    // ============ Edge Case #8: Vesting Distribution with Zero Stakers ============

    function test_ZeroStakers_VestingLost() public {
        // Same as above but focused on vesting
        vm.warp(seedTime + 24 hours + 30 days); // 30 days of vesting pass

        // Now alice stakes
        MockPair(pair).mint(alice, 1000e18);
        vm.startPrank(alice);
        IERC20(pair).approve(info.lpStaking, 1000e18);
        LPStaking(info.lpStaking).stake(1000e18);
        vm.stopPrank();

        // Pending should be 0 (vesting from past 30 days was lost)
        uint256 pending = LPStaking(info.lpStaking).pendingRewards(alice);
        assertEq(pending, 0, "Past vesting should be lost, no pending immediately");

        // But future vesting should work
        vm.warp(block.timestamp + 1 days);
        uint256 pendingAfter = LPStaking(info.lpStaking).pendingRewards(alice);
        assertGt(pendingAfter, 0, "Future vesting should accrue after staking");
    }

    // ============ Edge Case #24: Weekly Fee Epoch Transition ============

    function test_EpochTransition_LazyTrigger() public {
        MockPair(pair).mint(alice, 1000e18);
        vm.warp(seedTime + 24 hours + 1);

        vm.startPrank(alice);
        IERC20(pair).approve(info.lpStaking, 1000e18);
        LPStaking(info.lpStaking).stake(1000e18);
        vm.stopPrank();

        // Add fees to pending epoch
        deal(tokenAddr, info.feeDistributor, 150e18);
        vm.startPrank(info.feeDistributor);
        IERC20(tokenAddr).approve(info.lpStaking, 150e18);
        LPStaking(info.lpStaking).notifyFees(100e18);
        vm.stopPrank();

        assertEq(LPStaking(info.lpStaking).pendingEpochFees(), 100e18, "Fees should be pending");

        // Warp past epoch end (7 days from seedTime)
        vm.warp(seedTime + 7 days + 1);

        // notifyFees triggers epoch advance (calls _updateAllRewards internally)
        vm.prank(info.feeDistributor);
        LPStaking(info.lpStaking).notifyFees(50e18);

        assertEq(LPStaking(info.lpStaking).currentEpochFees(), 100e18, "Previous pending should become current");
        assertEq(LPStaking(info.lpStaking).pendingEpochFees(), 50e18, "New fees from trigger call");
    }

    // ============ Edge Case #25: Zero Staker Reward Loss (Both Streams) ============

    function test_ZeroStakerPeriod_BothVestingAndFeesLost() public {
        // Add fees while no stakers
        vm.warp(seedTime + 24 hours + 1);

        deal(tokenAddr, info.feeDistributor, 100e18);
        vm.startPrank(info.feeDistributor);
        IERC20(tokenAddr).approve(info.lpStaking, 100e18);
        LPStaking(info.lpStaking).notifyFees(100e18);
        vm.stopPrank();

        // Warp past epoch (fees + vesting accumulate, but no stakers)
        vm.warp(seedTime + 7 days + 1);

        // Alice staking triggers epoch advance (lazy — no separate trigger needed)
        MockPair(pair).mint(alice, 1000e18);
        vm.startPrank(alice);
        IERC20(pair).approve(info.lpStaking, 1000e18);
        LPStaking(info.lpStaking).stake(1000e18);
        vm.stopPrank();

        // Pending should be 0 (both past vesting and past fees were lost)
        uint256 pending = LPStaking(info.lpStaking).pendingRewards(alice);
        assertEq(pending, 0, "All past rewards should be lost");
    }

    // ============ Edge Case #28: Epoch Advance via notifyFees ============

    function test_NotifyFees_TriggersEpochAdvance() public {
        MockPair(pair).mint(alice, 1000e18);
        vm.warp(seedTime + 24 hours + 1);

        vm.startPrank(alice);
        IERC20(pair).approve(info.lpStaking, 1000e18);
        LPStaking(info.lpStaking).stake(1000e18);
        vm.stopPrank();

        // Add initial fees
        deal(tokenAddr, info.feeDistributor, 300e18);
        vm.startPrank(info.feeDistributor);
        IERC20(tokenAddr).approve(info.lpStaking, 300e18);
        LPStaking(info.lpStaking).notifyFees(200e18);
        vm.stopPrank();

        uint256 epochStartBefore = LPStaking(info.lpStaking).currentEpochStart();

        // Warp past epoch end
        vm.warp(epochStartBefore + 7 days + 1);

        // notifyFees triggers epoch advance (calls _updateAllRewards internally)
        vm.prank(info.feeDistributor);
        LPStaking(info.lpStaking).notifyFees(100e18);

        uint256 epochStartAfter = LPStaking(info.lpStaking).currentEpochStart();
        assertGt(epochStartAfter, epochStartBefore, "Epoch should have advanced");
    }

    // ============ Edge Case #35: Multi-Epoch Catch-Up ============

    function test_MultiEpochCatchUp_CorrectBehavior() public {
        MockPair(pair).mint(alice, 1000e18);
        vm.warp(seedTime + 24 hours + 1);

        vm.startPrank(alice);
        IERC20(pair).approve(info.lpStaking, 1000e18);
        LPStaking(info.lpStaking).stake(1000e18);
        vm.stopPrank();

        // Add fees
        deal(tokenAddr, info.feeDistributor, 150e18);
        vm.startPrank(info.feeDistributor);
        IERC20(tokenAddr).approve(info.lpStaking, 150e18);
        LPStaking(info.lpStaking).notifyFees(100e18);
        vm.stopPrank();

        // Skip 3 full epochs without interaction
        vm.warp(block.timestamp + 7 days * 3 + 1);

        // Trigger catch-up via notifyFees (calls _updateAllRewards → epoch advance)
        vm.prank(info.feeDistributor);
        LPStaking(info.lpStaking).notifyFees(50e18);

        // Epoch should be at current timestamp
        assertEq(LPStaking(info.lpStaking).currentEpochStart(), block.timestamp, "Epoch should anchor to now");
    }

    // ============ Stake → Earn → Claim → Withdraw Full Flow ============

    function test_FullStakingLifecycle() public {
        MockPair(pair).mint(alice, 1000e18);
        vm.warp(seedTime + 24 hours + 1);

        // 1. Stake
        vm.startPrank(alice);
        IERC20(pair).approve(info.lpStaking, 1000e18);
        LPStaking(info.lpStaking).stake(1000e18);
        vm.stopPrank();

        // 2. Warp for vesting + fees
        vm.warp(block.timestamp + 7 days);

        // 3. Claim vesting rewards
        uint256 pending = LPStaking(info.lpStaking).pendingRewards(alice);
        assertGt(pending, 0, "Should have pending rewards after 7 days");

        vm.prank(alice);
        uint256 claimed = LPStaking(info.lpStaking).claim();
        assertEq(claimed, pending, "Claimed should match pending");

        // 4. Withdraw half (burns proportional MP)
        vm.prank(alice);
        LPStaking(info.lpStaking).withdraw(500e18);

        (uint256 lpStaked,,,) = LPStaking(info.lpStaking).userInfo(alice);
        assertEq(lpStaked, 500e18, "Should have 500 LP remaining");

        // 5. Warp more and claim again
        vm.warp(block.timestamp + 3 days);
        uint256 pending2 = LPStaking(info.lpStaking).pendingRewards(alice);
        assertGt(pending2, 0, "Should earn more rewards");
    }
}

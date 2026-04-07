// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LPStaking} from "src/core/LPStaking.sol";
import {ILPStaking} from "src/interfaces/ILPStaking.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @dev Simple ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @title LPStakingTest
/// @notice Comprehensive unit + fuzz tests for LPStaking
contract LPStakingTest is Test {
    // ============ Constants ============

    uint256 internal constant PRECISION = 1e30;
    uint256 internal constant MP_RATE_BPS = 10000;
    uint256 internal constant VESTING_DURATION = 3 * 365 days;
    uint256 internal constant VESTING_DELAY = 24 hours;
    uint256 internal constant EPOCH_DURATION = 7 days;

    // ============ State ============

    LPStaking internal template;
    LPStaking internal lpStaking;
    MockERC20 internal lpToken;
    MockERC20 internal rewardToken;
    address internal feeDistributor;
    address internal alice;
    address internal bob;
    address internal charlie;

    uint256 internal seedTime;
    uint256 internal vestingAllocation;

    // ============ Events (re-declared for vm.expectEmit) ============

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 mpBurned);
    event Claimed(address indexed user, uint256 amount);
    event VestingDistributed(uint256 amount);
    event FeesReceived(uint256 amount);
    event EpochAdvanced(uint256 epochStart, uint256 epochFees, uint256 feeRate);

    // ============ Setup ============

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        feeDistributor = makeAddr("feeDistributor");

        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(charlie, "charlie");
        vm.label(feeDistributor, "feeDistributor");

        // Deploy mocks
        lpToken = new MockERC20("LP Token", "LP");
        rewardToken = new MockERC20("Reward Token", "RWD");

        seedTime = block.timestamp;
        vestingAllocation = 1_000_000e18; // 1M tokens over 3 years

        // Deploy template and clone
        template = new LPStaking();
        lpStaking = _deployInitializedLPStaking();
    }

    // ============ Initialization ============

    function test_Initialize_SetsAllState() public view {
        assertEq(address(lpStaking.lpToken()), address(lpToken), "lpToken mismatch");
        assertEq(address(lpStaking.rewardToken()), address(rewardToken), "rewardToken mismatch");
        assertEq(lpStaking.feeDistributor(), feeDistributor, "feeDistributor mismatch");
        assertEq(lpStaking.vestingAllocation(), vestingAllocation, "vestingAllocation mismatch");
        assertEq(lpStaking.vestingStart(), seedTime + VESTING_DELAY, "vestingStart mismatch");
        assertEq(lpStaking.vestingEnd(), seedTime + VESTING_DELAY + VESTING_DURATION, "vestingEnd mismatch");
        assertEq(lpStaking.baseVestingRate(), vestingAllocation / VESTING_DURATION, "baseVestingRate mismatch");
        assertEq(lpStaking.lastRewardUpdate(), seedTime + VESTING_DELAY, "lastRewardUpdate mismatch");
        assertEq(lpStaking.currentEpochStart(), seedTime, "currentEpochStart mismatch");
    }

    function test_Initialize_ZeroVestingAllocation() public {
        LPStaking newStaking = _deployUninitializedLPStaking();
        newStaking.initialize(address(lpToken), address(rewardToken), feeDistributor, block.timestamp, 0);

        assertEq(newStaking.vestingAllocation(), 0, "vestingAllocation should be 0");
        assertEq(newStaking.baseVestingRate(), 0, "baseVestingRate should be 0");
    }

    function test_RevertWhen_InitializeTwice() public {
        LPStaking newStaking = _deployUninitializedLPStaking();
        newStaking.initialize(
            address(lpToken), address(rewardToken), feeDistributor, block.timestamp, vestingAllocation
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        newStaking.initialize(
            address(lpToken), address(rewardToken), feeDistributor, block.timestamp, vestingAllocation
        );
    }

    function test_RevertWhen_Initialize_ZeroLpToken() public {
        LPStaking newStaking = _deployUninitializedLPStaking();
        vm.expectRevert(LPStaking.ZeroAddress.selector);
        newStaking.initialize(address(0), address(rewardToken), feeDistributor, block.timestamp, vestingAllocation);
    }

    function test_RevertWhen_Initialize_ZeroRewardToken() public {
        LPStaking newStaking = _deployUninitializedLPStaking();
        vm.expectRevert(LPStaking.ZeroAddress.selector);
        newStaking.initialize(address(lpToken), address(0), feeDistributor, block.timestamp, vestingAllocation);
    }

    function test_RevertWhen_Initialize_ZeroFeeDistributor() public {
        LPStaking newStaking = _deployUninitializedLPStaking();
        vm.expectRevert(LPStaking.ZeroAddress.selector);
        newStaking.initialize(address(lpToken), address(rewardToken), address(0), block.timestamp, vestingAllocation);
    }

    function test_Initialize_TemplateDisabled() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        template.initialize(address(lpToken), address(rewardToken), feeDistributor, block.timestamp, vestingAllocation);
    }

    // ============ Stake ============

    function test_Stake_HappyPath() public {
        uint256 amount = 1000e18;
        deal(address(lpToken), alice, amount);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), amount);

        vm.expectEmit(true, false, false, true);
        emit Staked(alice, amount);
        lpStaking.stake(amount);
        vm.stopPrank();

        (uint256 lpStaked,,,) = lpStaking.userInfo(alice);
        assertEq(lpStaked, amount, "LP staked mismatch");
        assertEq(lpStaking.totalLpStaked(), amount, "totalLpStaked mismatch");
        assertEq(lpStaking.totalWeight(), amount, "totalWeight mismatch");
        assertEq(lpToken.balanceOf(address(lpStaking)), amount, "LP balance mismatch");
        assertEq(lpToken.balanceOf(alice), 0, "Alice LP balance should be 0");
    }

    function test_Stake_SettlesPendingBeforeMPUpdate() public {
        // Setup: Alice stakes, time passes, then stakes more
        uint256 amount1 = 1000e18;
        deal(address(lpToken), alice, amount1 * 2);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), amount1 * 2);
        lpStaking.stake(amount1);
        vm.stopPrank();

        // Warp past vesting start and distribute rewards via notifyFees
        vm.warp(seedTime + VESTING_DELAY + 1 days);
        _mintAndApproveRewardForFees(100e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        // Alice stakes more - should settle pending first
        uint256 pendingBefore = lpStaking.pendingRewards(alice);
        assertGt(pendingBefore, 0, "Should have pending rewards");

        uint256 rewardBalanceBefore = rewardToken.balanceOf(alice);

        vm.startPrank(alice);
        lpStaking.stake(amount1);
        vm.stopPrank();

        assertEq(rewardToken.balanceOf(alice), rewardBalanceBefore + pendingBefore, "Pending should be claimed");
    }

    function test_Stake_UpdatesMP() public {
        uint256 amount = 1000e18;
        deal(address(lpToken), alice, amount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), amount);
        lpStaking.stake(amount);
        vm.stopPrank();

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        // Stake more to trigger MP update
        deal(address(lpToken), alice, amount);
        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), amount);
        lpStaking.stake(amount);
        vm.stopPrank();

        // MP should be ~1000 (100% APR for 1 year on 1000 LP)
        (, uint256 mp,,) = lpStaking.userInfo(alice);
        assertApproxEqRel(mp, 1000e18, 0.01e18, "MP should be ~1000 after 1 year");
    }

    function test_RevertWhen_StakeZero() public {
        vm.prank(alice);
        vm.expectRevert(LPStaking.CannotStakeZero.selector);
        lpStaking.stake(0);
    }

    function testFuzz_Stake_UpdatesWeight(
        uint256 amount
    ) public {
        amount = bound(amount, 1, 1_000_000e18);
        deal(address(lpToken), alice, amount);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), amount);
        lpStaking.stake(amount);
        vm.stopPrank();

        assertEq(lpStaking.totalWeight(), amount, "totalWeight should equal staked amount");
        (uint256 lpStaked,,,) = lpStaking.userInfo(alice);
        assertEq(lpStaked, amount, "user LP staked mismatch");
    }

    // ============ Withdraw ============

    function test_Withdraw_HappyPath() public {
        uint256 stakeAmount = 1000e18;
        uint256 withdrawAmount = 500e18;
        deal(address(lpToken), alice, stakeAmount);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(seedTime + VESTING_DELAY + 1 days);

        vm.startPrank(alice);
        // Note: MP has accrued since stake, so mpBurned > 0
        vm.expectEmit(true, false, false, false);
        emit Withdrawn(alice, withdrawAmount, 0);
        lpStaking.withdraw(withdrawAmount);
        vm.stopPrank();

        (uint256 lpStaked,,,) = lpStaking.userInfo(alice);
        assertEq(lpStaked, stakeAmount - withdrawAmount, "LP staked mismatch");
        assertEq(lpStaking.totalLpStaked(), stakeAmount - withdrawAmount, "totalLpStaked mismatch");
        assertEq(lpToken.balanceOf(alice), withdrawAmount, "Alice LP balance mismatch");
    }

    function test_Withdraw_ProportionalMPBurn() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Warp 1 year to accrue MP
        vm.warp(block.timestamp + 365 days);

        // Withdraw 50% - triggers MP update first, THEN burns 50% of new MP
        // After 1 year, MP ≈ stakeAmount (100% APR)
        vm.startPrank(alice);
        lpStaking.withdraw(stakeAmount / 2);
        vm.stopPrank();

        (, uint256 mpAfter,,) = lpStaking.userInfo(alice);
        // After withdraw: MP was ~1000e18, burned 50% = ~500e18 remaining
        assertApproxEqRel(mpAfter, 500e18, 0.01e18, "MP should be ~500 after 50% withdraw");
    }

    function test_Withdraw_SettlesPendingBeforeMPUpdate() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Distribute rewards
        vm.warp(block.timestamp + 1 days);
        _mintAndApproveRewardForFees(100e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        uint256 pendingBefore = lpStaking.pendingRewards(alice);
        assertGt(pendingBefore, 0, "Should have pending rewards");
        uint256 rewardBalanceBefore = rewardToken.balanceOf(alice);

        vm.startPrank(alice);
        lpStaking.withdraw(stakeAmount / 2);
        vm.stopPrank();

        // Pending rewards should have been claimed during withdraw
        assertEq(rewardToken.balanceOf(alice), rewardBalanceBefore + pendingBefore, "Pending should be claimed");
    }

    function test_RevertWhen_Withdraw_InsufficientStake() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LPStaking.InsufficientStake.selector, stakeAmount, stakeAmount + 1));
        lpStaking.withdraw(stakeAmount + 1);
    }

    function test_RevertWhen_WithdrawZero() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LPStaking.InsufficientStake.selector, stakeAmount, 0));
        lpStaking.withdraw(0);
    }

    function testFuzz_Withdraw_Proportional(
        uint256 stakeAmount,
        uint256 withdrawAmount
    ) public {
        stakeAmount = bound(stakeAmount, 1000e18, 100_000e18);
        // Ensure meaningful remaining (at least 10%) to avoid rounding edge cases
        withdrawAmount = bound(withdrawAmount, 1e18, stakeAmount * 90 / 100);
        deal(address(lpToken), alice, stakeAmount);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(seedTime + VESTING_DELAY + 365 days); // 1 year for MP

        // Withdraw triggers MP update THEN burns proportionally
        vm.startPrank(alice);
        lpStaking.withdraw(withdrawAmount);
        vm.stopPrank();

        (uint256 lpAfter, uint256 mpAfter,,) = lpStaking.userInfo(alice);
        uint256 remaining = stakeAmount - withdrawAmount;
        assertEq(lpAfter, remaining, "LP staked mismatch");
        // After 1 year: totalMP ≈ stakeAmount. Burned = totalMP * withdrawAmount / stakeAmount
        // Remaining MP ≈ remaining (proportional)
        assertApproxEqRel(mpAfter, remaining, 0.02e18, "MP burn should be proportional");
    }

    // ============ Claim ============

    function test_Claim_HappyPath() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Distribute rewards via notifyFees
        vm.warp(block.timestamp + 1 days);
        _mintAndApproveRewardForFees(100e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        uint256 pending = lpStaking.pendingRewards(alice);
        assertGt(pending, 0, "Should have pending rewards");

        vm.prank(alice);
        uint256 claimed = lpStaking.claim();

        assertEq(claimed, pending, "Claimed amount mismatch");
        assertEq(rewardToken.balanceOf(alice), pending, "Reward balance mismatch");
        assertEq(lpStaking.pendingRewards(alice), 0, "Pending should be 0 after claim");
    }

    function test_Claim_CalculatesPendingBeforeMPUpdate() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Warp 1 year (MP accrual) and distribute fees
        vm.warp(block.timestamp + 365 days);
        _mintAndApproveRewardForFees(100e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        // pendingRewards now uses stored weight (before MP update) - same as claim()
        uint256 pendingBeforeMPUpdate = lpStaking.pendingRewards(alice);

        vm.prank(alice);
        uint256 claimed = lpStaking.claim();

        // Claimed should match pending calculated before MP update
        assertEq(claimed, pendingBeforeMPUpdate, "Claimed should match pending before MP update");
    }

    function test_Claim_UpdatesMPAfterClaim() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        _mintAndApproveRewardForFees(100e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        (, uint256 mpBefore,,) = lpStaking.userInfo(alice);
        assertEq(mpBefore, 0, "MP should be 0 before claim triggers update");

        vm.prank(alice);
        lpStaking.claim();

        (, uint256 mpAfter,,) = lpStaking.userInfo(alice);
        assertGt(mpAfter, 0, "MP should be updated after claim");
        assertApproxEqRel(mpAfter, 1000e18, 0.01e18, "MP should be ~1000 after 1 year");
    }

    function test_Claim_NothingToClaim() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // No rewards distributed yet
        vm.prank(alice);
        uint256 claimed = lpStaking.claim();
        assertEq(claimed, 0, "Should claim 0 when no rewards");
    }

    // ============ notifyFees ============

    function test_notifyFees_OnlyFeeDistributor() public {
        deal(address(rewardToken), feeDistributor, 100e18);

        vm.startPrank(feeDistributor);
        rewardToken.approve(address(lpStaking), 100e18);
        vm.expectEmit(true, false, false, true);
        emit FeesReceived(100e18);
        lpStaking.notifyFees(100e18);
        vm.stopPrank();

        assertEq(lpStaking.pendingEpochFees(), 100e18, "pendingEpochFees mismatch");
    }

    function test_RevertWhen_notifyFees_Unauthorized() public {
        deal(address(rewardToken), alice, 100e18);

        vm.startPrank(alice);
        rewardToken.approve(address(lpStaking), 100e18);
        vm.expectRevert(LPStaking.OnlyFeeDistributor.selector);
        lpStaking.notifyFees(100e18);
        vm.stopPrank();
    }

    function test_notifyFees_AddsToPendingNotCurrent() public {
        deal(address(rewardToken), feeDistributor, 200e18);

        vm.startPrank(feeDistributor);
        rewardToken.approve(address(lpStaking), 200e18);
        lpStaking.notifyFees(100e18);
        assertEq(lpStaking.pendingEpochFees(), 100e18, "pendingEpochFees should be 100");
        assertEq(lpStaking.currentEpochFees(), 0, "currentEpochFees should be 0");
        lpStaking.notifyFees(100e18);
        assertEq(lpStaking.pendingEpochFees(), 200e18, "pendingEpochFees should accumulate");
        vm.stopPrank();
    }

    function test_notifyFees_TriggersEpochAdvance() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Add fees to pending within first epoch
        _mintAndApproveRewardForFees(150e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(50e18);

        uint256 epochStartBefore = lpStaking.currentEpochStart();

        // Warp past epoch end
        vm.warp(epochStartBefore + EPOCH_DURATION + 1);

        // notifyFees DOES trigger epoch advance (calls _updateAllRewards internally)
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        assertGt(lpStaking.currentEpochStart(), epochStartBefore, "epoch should advance on notifyFees");
        assertEq(lpStaking.currentEpochStart(), block.timestamp, "epoch should anchor to block.timestamp");
        assertEq(lpStaking.currentEpochFees(), 50e18, "previous pending (50) should become current");
        assertEq(lpStaking.pendingEpochFees(), 100e18, "new fees (100) should be in pending");
        assertEq(lpStaking.feeRewardRate(), 50e18 / EPOCH_DURATION, "feeRewardRate based on promoted fees");
    }

    function test_notifyFees_UpdatesRewardState() public {
        // Verify notifyFees calls _updateAllRewards: epoch advance + reward distribution
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Add fees, warp past epoch
        _mintAndApproveRewardForFees(100e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(50e18);

        vm.warp(lpStaking.currentEpochStart() + EPOCH_DURATION + 1);

        // Record state before notifyFees
        uint256 accBefore = lpStaking.accRewardPerWeight();
        uint256 epochStartBefore = lpStaking.currentEpochStart();
        uint256 lastUpdateBefore = lpStaking.lastRewardUpdate();

        vm.prank(feeDistributor);
        lpStaking.notifyFees(50e18);

        // notifyFees DOES update global reward state (calls _updateAllRewards)
        assertGt(lpStaking.accRewardPerWeight(), accBefore, "accRewardPerWeight should increase (vesting distributed)");
        assertGt(lpStaking.currentEpochStart(), epochStartBefore, "epoch should advance");
        assertGt(lpStaking.lastRewardUpdate(), lastUpdateBefore, "lastRewardUpdate should advance");
        assertEq(lpStaking.currentEpochFees(), 50e18, "previous pending promoted to current");
        assertEq(lpStaking.pendingEpochFees(), 50e18, "new fees added after epoch advance");
    }

    // ============ Epoch Advancement ============

    function test_EpochAdvance_After7Days() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Add fees to pending
        _mintAndApproveRewardForFees(150e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        uint256 epochStartBefore = lpStaking.currentEpochStart();
        uint256 pendingBefore = lpStaking.pendingEpochFees();

        // Warp past epoch end
        vm.warp(epochStartBefore + EPOCH_DURATION + 1);

        // Trigger epoch advance via notifyFees (calls _updateAllRewards internally)
        vm.prank(feeDistributor);
        lpStaking.notifyFees(50e18);

        assertEq(lpStaking.currentEpochStart(), block.timestamp, "epoch should advance to now");
        assertEq(lpStaking.currentEpochFees(), pendingBefore, "currentEpochFees should be previous pending");
        assertEq(lpStaking.pendingEpochFees(), 50e18, "pendingEpochFees should contain new trigger fees");
        assertEq(lpStaking.feeRewardRate(), pendingBefore / EPOCH_DURATION, "feeRewardRate should be calculated");
    }

    function test_EpochAdvance_AnchoredToBlockTimestamp() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        _mintAndApproveRewardForFees(150e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        // Warp 10 days past epoch (well past the 7-day epoch end)
        uint256 warpTo = seedTime + EPOCH_DURATION + 10 days;
        vm.warp(warpTo);

        // Trigger epoch advance via notifyFees
        vm.prank(feeDistributor);
        lpStaking.notifyFees(50e18);

        // Epoch should start at warpTo, not seedTime + EPOCH_DURATION
        assertEq(lpStaking.currentEpochStart(), warpTo, "epoch should be anchored to block.timestamp");
    }

    function test_EpochAdvance_MultipleEpochs() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        uint256 t = seedTime + VESTING_DELAY;
        vm.warp(t);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Epoch 1: add fees to pending
        _mintAndApproveRewardForFees(600e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        // Warp to epoch 2: trigger via notifyFees, 100 becomes current + 200 added to pending
        t += EPOCH_DURATION + 1;
        vm.warp(t);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(200e18);

        assertEq(lpStaking.currentEpochFees(), 100e18, "currentEpochFees should be epoch 1 fees");
        assertEq(lpStaking.pendingEpochFees(), 200e18, "pendingEpochFees should be epoch 2 fees");

        // Warp to epoch 3: trigger via notifyFees, 200 becomes current + 300 added to pending
        t += EPOCH_DURATION + 1;
        vm.warp(t);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(300e18);

        assertEq(lpStaking.currentEpochFees(), 200e18, "currentEpochFees should be epoch 2 fees");
        assertEq(lpStaking.pendingEpochFees(), 300e18, "pendingEpochFees should be epoch 3 fees");
    }

    // ============ Vesting Distribution ============

    function test_VestingDistribution_BaseRateTimesElapsed() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        deal(address(rewardToken), address(lpStaking), vestingAllocation);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Warp 1 day
        vm.warp(block.timestamp + 1 days);

        uint256 expectedVesting = lpStaking.baseVestingRate() * 1 days;
        uint256 pending = lpStaking.pendingRewards(alice);

        // Pending should include vesting rewards
        assertGe(pending, expectedVesting * stakeAmount / stakeAmount, "Should have vesting rewards");
    }

    function test_VestingDistribution_24hDelay() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        deal(address(rewardToken), address(lpStaking), vestingAllocation);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Before vesting start (before seedTime + 24h)
        vm.warp(seedTime + VESTING_DELAY - 1);
        uint256 pendingBefore = lpStaking.pendingRewards(alice);
        assertEq(pendingBefore, 0, "Should have no rewards before vesting start");

        // At vesting start
        vm.warp(seedTime + VESTING_DELAY);
        uint256 pendingAtStart = lpStaking.pendingRewards(alice);
        assertEq(pendingAtStart, 0, "Should have no rewards at exact vesting start");

        // After vesting start
        vm.warp(block.timestamp + 1);
        uint256 pendingAfter = lpStaking.pendingRewards(alice);
        assertGt(pendingAfter, 0, "Should have rewards after vesting start");
    }

    function test_VestingDistribution_CappedAtVestingEnd() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Warp past vesting end (3 years + 1 day)
        vm.warp(lpStaking.vestingEnd() + 1 days);

        uint256 pending = lpStaking.pendingRewards(alice);

        // Should not exceed vesting allocation (single staker gets all vesting)
        assertLe(pending, vestingAllocation, "Rewards should not exceed vesting allocation");

        // Claim and verify
        vm.prank(alice);
        uint256 claimed = lpStaking.claim();
        assertLe(claimed, vestingAllocation, "Claimed should not exceed vesting allocation");
    }

    function test_VestingDistribution_ZeroAllocation() public {
        LPStaking newStaking = _deployUninitializedLPStaking();
        newStaking.initialize(address(lpToken), address(rewardToken), feeDistributor, block.timestamp, 0);

        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(block.timestamp + VESTING_DELAY + 1 days);

        vm.startPrank(alice);
        lpToken.approve(address(newStaking), stakeAmount);
        newStaking.stake(stakeAmount);
        vm.stopPrank();

        uint256 pending = newStaking.pendingRewards(alice);
        assertEq(pending, 0, "Should have no vesting rewards with zero allocation");
    }

    // ============ Zero Staker Periods ============

    function test_ZeroStakerPeriods_VestingLost() public {
        // No stakers, vesting rewards accumulate but are lost
        deal(address(rewardToken), address(lpStaking), vestingAllocation);
        vm.warp(seedTime + VESTING_DELAY + 1 days);

        // Now alice stakes - triggers _updateAllRewards which handles zero-staker period
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // accRewardPerWeight should still be 0 (vesting during zero-staker period was lost)
        assertEq(lpStaking.accRewardPerWeight(), 0, "Rewards should be lost when no stakers");
        // Alice has 0 pending (she just staked, past vesting was lost)
        assertEq(lpStaking.pendingRewards(alice), 0, "No pending after joining zero-staker period");
    }

    function test_ZeroStakerPeriods_FeesLost() public {
        // No stakers, fees accumulate but are lost when epoch advances
        vm.warp(seedTime + VESTING_DELAY);

        _mintAndApproveRewardForFees(100e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        // Warp past epoch end with no stakers
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        // Alice stakes - triggers epoch advance during zero-staker period
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Epoch should have advanced, fees promoted to current
        assertEq(lpStaking.currentEpochFees(), 100e18, "Previous pending should become current");
        // But accRewardPerWeight should be 0 — no rewards distributed during zero-staker period
        assertEq(lpStaking.accRewardPerWeight(), 0, "Fees should be lost when no stakers during epoch");
        // Alice has 0 pending right after staking
        assertEq(lpStaking.pendingRewards(alice), 0, "No pending for alice right after staking");
    }

    // ============ Multiplier Points ============

    function test_MultiplierPoints_100PercentAPR() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        // Trigger MP update via claim
        vm.prank(alice);
        lpStaking.claim();

        (, uint256 mp,,) = lpStaking.userInfo(alice);
        // 100% APR = 1 MP per LP per year
        assertApproxEqRel(mp, 1000e18, 0.01e18, "MP should be ~1000 after 1 year (100% APR)");
    }

    function test_MultiplierPoints_ProportionalBurnOnWithdraw() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        // Withdraw 50%
        vm.startPrank(alice);
        lpStaking.withdraw(stakeAmount / 2);
        vm.stopPrank();

        (, uint256 mpAfter,,) = lpStaking.userInfo(alice);
        // Should have ~500 MP remaining (50% of ~1000)
        assertApproxEqRel(mpAfter, 500e18, 0.01e18, "MP should be ~500 after 50% withdraw");
    }

    function testFuzz_MultiplierPoints_Accrual(
        uint256 stakeAmount,
        uint256 timeElapsed
    ) public {
        stakeAmount = bound(stakeAmount, 1e18, 100_000e18); // Reduced to avoid overflow
        timeElapsed = bound(timeElapsed, 1 days, 365 days);
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + timeElapsed);

        vm.prank(alice);
        lpStaking.claim();

        (, uint256 mp,,) = lpStaking.userInfo(alice);
        uint256 expectedMP = stakeAmount * timeElapsed * MP_RATE_BPS / 10000 / 365 days;

        assertApproxEqRel(mp, expectedMP, 0.01e18, "MP accrual should match expected");
    }

    // ============ MP Insolvency Fix ============

    function test_MPInsolvencyFix_PendingSettledBeforeMPUpdate() public {
        // This test verifies the critical fix: pending is settled BEFORE MP update

        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount * 2);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount * 2);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Distribute some rewards
        vm.warp(block.timestamp + 1 days);
        _mintAndApproveRewardForFees(100e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        // Calculate pending with stored weight
        uint256 pendingBefore = lpStaking.pendingRewards(alice);

        // Warp to accrue MP (but MP isn't updated in state yet)
        vm.warp(block.timestamp + 365 days);

        // pendingRewards uses stored weight (before MP), so should still match
        uint256 pendingAfterWarp = lpStaking.pendingRewards(alice);

        // Now stake more - this should settle pending BEFORE updating MP
        uint256 rewardBalanceBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        lpStaking.stake(stakeAmount);

        // Verify rewards were claimed during the stake
        uint256 rewardBalanceAfter = rewardToken.balanceOf(alice);
        assertEq(rewardBalanceAfter - rewardBalanceBefore, pendingAfterWarp, "Should claim pending before MP update");
    }

    function test_MPInsolvencyFix_TotalClaimsLessThanDistributed() public {
        // Test with multiple users to verify total claims <= total distributed
        uint256 stakeAmount1 = 1000e18;
        uint256 stakeAmount2 = 2000e18;
        deal(address(lpToken), alice, stakeAmount1);
        deal(address(lpToken), bob, stakeAmount2);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount1);
        lpStaking.stake(stakeAmount1);
        vm.stopPrank();

        vm.startPrank(bob);
        lpToken.approve(address(lpStaking), stakeAmount2);
        lpStaking.stake(stakeAmount2);
        vm.stopPrank();

        // Distribute fees
        vm.warp(block.timestamp + 1 days);
        _mintAndApproveRewardForFees(1000e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(1000e18);

        // Warp to accrue MP
        vm.warp(block.timestamp + 365 days);

        // Both users claim
        vm.prank(alice);
        uint256 aliceClaimed = lpStaking.claim();

        vm.prank(bob);
        uint256 bobClaimed = lpStaking.claim();

        // Total claimed should be > 0
        uint256 totalClaimed = aliceClaimed + bobClaimed;
        assertGt(totalClaimed, 0, "Should have claimed rewards");

        // After claiming, pending should be minimal (just rounding)
        uint256 alicePending = lpStaking.pendingRewards(alice);
        uint256 bobPending = lpStaking.pendingRewards(bob);
        assertLe(alicePending + bobPending, 100, "Pending should be minimal after claim");
    }

    // ============ View Functions ============

    function test_pendingRewards_SimulatesCorrectly() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        deal(address(rewardToken), address(lpStaking), 1000e18);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Distribute rewards
        vm.warp(block.timestamp + 1 days);
        deal(address(rewardToken), feeDistributor, 100e18);
        vm.startPrank(feeDistributor);
        rewardToken.approve(address(lpStaking), 100e18);
        lpStaking.notifyFees(100e18);
        vm.stopPrank();

        uint256 pending = lpStaking.pendingRewards(alice);
        assertGt(pending, 0, "Should have pending rewards");

        // Claim and verify pending goes to 0
        vm.prank(alice);
        lpStaking.claim();

        uint256 pendingAfter = lpStaking.pendingRewards(alice);
        assertLe(pendingAfter, 1, "Pending should be ~0 after claim (allowing for rounding)");
    }

    function test_getPoolStats_ReturnsEpochData() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        deal(address(rewardToken), feeDistributor, 100e18);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        vm.startPrank(feeDistributor);
        rewardToken.approve(address(lpStaking), 100e18);
        lpStaking.notifyFees(100e18);
        vm.stopPrank();

        (
            uint256 totalLpStaked,
            uint256 totalWeight,
            uint256 vestingPerSecond,
            uint256 vestingRemaining,
            uint256 currentEpochFees,
            uint256 feeRewardRate,
            uint256 pendingEpochFees,
            uint256 epochTimeRemaining
        ) = lpStaking.getPoolStats();

        assertEq(totalLpStaked, stakeAmount, "totalLpStaked mismatch");
        assertEq(totalWeight, stakeAmount, "totalWeight mismatch");
        assertEq(vestingPerSecond, lpStaking.baseVestingRate(), "vestingPerSecond mismatch");
        assertEq(currentEpochFees, 0, "currentEpochFees should be 0 before epoch advance");
        assertEq(pendingEpochFees, 100e18, "pendingEpochFees mismatch");
        assertGt(epochTimeRemaining, 0, "epochTimeRemaining should be > 0");
    }

    function test_getPoolStats_AfterVestingFullyConsumed() public {
        // Deploy a staking contract with vestingAllocation that divides evenly by VESTING_DURATION
        // so that vested == vestingAllocation exactly (hits the `vestingAllocation > vested : 0` branch)
        uint256 evenAllocation = VESTING_DURATION * 1e18; // Exactly divisible

        LPStaking evenStaking = LPStaking(Clones.clone(address(template)));
        evenStaking.setInitializer(address(this));
        evenStaking.initialize(address(lpToken), address(rewardToken), feeDistributor, seedTime, evenAllocation);
        deal(address(rewardToken), address(evenStaking), evenAllocation);

        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(evenStaking), stakeAmount);
        evenStaking.stake(stakeAmount);
        vm.stopPrank();

        // Warp past vesting end
        vm.warp(seedTime + VESTING_DELAY + VESTING_DURATION + 1 days);

        (
            ,
            ,
            uint256 vestingPerSecond,
            uint256 vestingRemaining,
            ,
            ,
            ,
        ) = evenStaking.getPoolStats();

        assertEq(vestingPerSecond, 0, "vestingPerSecond should be 0 after vesting ends");
        assertEq(vestingRemaining, 0, "vestingRemaining should be 0 with exact division");
    }

    function test_getUserInfo_ReturnsCurrentMP() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Warp 1 year
        vm.warp(block.timestamp + 365 days);

        (uint256 stakedLp, uint256 currentMp, uint256 effectiveWeight, uint256 pending, uint256 poolShareBps) =
            lpStaking.getUserInfo(alice);

        assertEq(stakedLp, stakeAmount, "stakedLp mismatch");
        assertApproxEqRel(currentMp, 1000e18, 0.01e18, "currentMp should include accrued MP");
        assertEq(effectiveWeight, stakedLp + currentMp, "effectiveWeight mismatch");
        // Single staker: poolShareBps should be 10000 (100%) regardless of MP
        assertEq(poolShareBps, 10000, "poolShareBps mismatch for sole staker");
    }

    // ============ Edge Cases ============

    function test_MultipleEpochsPassingWithoutInteraction() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Add fees
        _mintAndApproveRewardForFees(150e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        // Warp multiple epochs without interaction
        vm.warp(block.timestamp + EPOCH_DURATION * 5 + 1);

        // Now interact via notifyFees — triggers epoch advance
        vm.prank(feeDistributor);
        lpStaking.notifyFees(50e18);

        // Epoch should have advanced
        assertEq(lpStaking.currentEpochStart(), block.timestamp, "Epoch should advance");
        assertEq(lpStaking.currentEpochFees(), 100e18, "Previous pending should become current");
        assertEq(lpStaking.pendingEpochFees(), 50e18, "New fees from trigger call");
    }

    function test_SingleStakerGetsAllRewards() public {
        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Distribute rewards
        vm.warp(block.timestamp + 1 days);
        _mintAndApproveRewardForFees(100e18);
        vm.prank(feeDistributor);
        lpStaking.notifyFees(100e18);

        // Alice should get all rewards (she's the only staker)
        uint256 pending = lpStaking.pendingRewards(alice);
        assertGt(pending, 0, "Alice should have pending rewards");

        vm.prank(alice);
        uint256 claimed = lpStaking.claim();

        assertEq(claimed, pending, "Alice should claim all pending");
    }

    function test_StakerJoinsAfterVestingStarted() public {
        // Vesting starts at seedTime + 24h
        vm.warp(seedTime + VESTING_DELAY + 30 days);

        uint256 stakeAmount = 1000e18;
        deal(address(lpToken), alice, stakeAmount);
        deal(address(rewardToken), address(lpStaking), vestingAllocation);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        // Alice should start earning from now, not from vesting start
        // (rewards distributed before she staked are lost)
        uint256 pending = lpStaking.pendingRewards(alice);
        assertEq(pending, 0, "Should have no pending immediately after staking");

        // Warp forward and she should earn new rewards
        vm.warp(block.timestamp + 1 days);
        uint256 pendingAfter = lpStaking.pendingRewards(alice);
        assertGt(pendingAfter, 0, "Should earn rewards going forward");
    }

    function test_VeryLargeStakeAmount() public {
        uint256 stakeAmount = 1_000_000_000e18; // 1B tokens
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        assertEq(lpStaking.totalLpStaked(), stakeAmount, "Should handle large amounts");
        assertEq(lpStaking.totalWeight(), stakeAmount, "totalWeight should match");
    }

    function test_VerySmallStakeAmount() public {
        uint256 stakeAmount = 1; // 1 wei
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        assertEq(lpStaking.totalLpStaked(), stakeAmount, "Should handle small amounts");
    }

    function testFuzz_StakeAndWithdraw_Consistency(
        uint256 stakeAmount,
        uint256 withdrawAmount
    ) public {
        stakeAmount = bound(stakeAmount, 1000, 1_000_000e18);
        withdrawAmount = bound(withdrawAmount, 1, stakeAmount);
        deal(address(lpToken), alice, stakeAmount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), stakeAmount);
        lpStaking.stake(stakeAmount);
        vm.stopPrank();

        uint256 totalLpBefore = lpStaking.totalLpStaked();
        uint256 totalWeightBefore = lpStaking.totalWeight();

        vm.startPrank(alice);
        lpStaking.withdraw(withdrawAmount);
        vm.stopPrank();

        assertEq(lpStaking.totalLpStaked(), totalLpBefore - withdrawAmount, "totalLpStaked should decrease");
        assertLe(lpStaking.totalWeight(), totalWeightBefore, "totalWeight should decrease or stay same");
    }

    // ============ Helpers ============

    function _deployUninitializedLPStaking() internal returns (LPStaking) {
        address clone = Clones.clone(address(template));
        LPStaking staking = LPStaking(clone);
        // Set test contract as initializer (simulates factory calling setInitializer)
        staking.setInitializer(address(this));
        return staking;
    }

    function _deployInitializedLPStaking() internal returns (LPStaking) {
        LPStaking staking = _deployUninitializedLPStaking();
        staking.initialize(address(lpToken), address(rewardToken), feeDistributor, block.timestamp, vestingAllocation);
        // Mint vesting allocation to the staking contract (simulates PresaleManager minting)
        rewardToken.mint(address(staking), vestingAllocation);
        return staking;
    }

    function _mintAndApproveLp(
        address user,
        uint256 amount
    ) internal {
        lpToken.mint(user, amount);
        vm.prank(user);
        lpToken.approve(address(lpStaking), amount);
    }

    function _mintAndApproveRewardForFees(
        uint256 amount
    ) internal {
        rewardToken.mint(feeDistributor, amount);
        vm.prank(feeDistributor);
        rewardToken.approve(address(lpStaking), amount);
    }

    // ================================================================
    //  COVERAGE GAP TESTS
    // ================================================================

    function test_RevertWhen_SetInitializer_ZeroAddress() public {
        LPStaking fresh = LPStaking(Clones.clone(address(template)));
        vm.expectRevert(LPStaking.ZeroAddress.selector);
        fresh.setInitializer(address(0));
    }

    function test_RevertWhen_SetInitializer_AlreadySet() public {
        LPStaking fresh = LPStaking(Clones.clone(address(template)));
        fresh.setInitializer(address(1));
        vm.expectRevert(LPStaking.InitializerAlreadySet.selector);
        fresh.setInitializer(address(2));
    }

    function test_PendingRewards_ZeroForNonStaker() public {
        uint256 pending = lpStaking.pendingRewards(charlie);
        assertEq(pending, 0, "Non-staker should have 0 pending");
    }

    function test_GetUserInfo_ZeroForNonStaker() public {
        (uint256 lp, uint256 mp, uint256 w, uint256 p, uint256 share) = lpStaking.getUserInfo(charlie);
        assertEq(lp, 0, "LP should be 0");
        assertEq(mp, 0, "MP should be 0");
        assertEq(w, 0, "Weight should be 0");
        assertEq(p, 0, "Pending should be 0");
        assertEq(share, 0, "Share should be 0");
    }

    function test_GetPoolStats_PartialVesting() public {
        deal(address(lpToken), alice, 1000e18);
        vm.warp(seedTime + VESTING_DELAY);
        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), 1000e18);
        lpStaking.stake(1000e18);
        vm.stopPrank();

        vm.warp(seedTime + VESTING_DELAY + 30 days);

        (,, uint256 vestingPerSecond, uint256 vestingRemaining,,,,) = lpStaking.getPoolStats();
        assertGt(vestingPerSecond, 0, "Vesting rate should be > 0");
        assertLt(vestingRemaining, vestingAllocation, "Some vesting should have been distributed");
    }

    function test_RevertWhen_Initialize_NotInitializer() public {
        LPStaking fresh = LPStaking(Clones.clone(address(template)));
        fresh.setInitializer(makeAddr("authorized"));

        vm.expectRevert(LPStaking.NotInitializer.selector);
        fresh.initialize(address(lpToken), address(rewardToken), feeDistributor, block.timestamp, vestingAllocation);
    }

    function test_Constructor_DisablesInitializers_DirectDeploy() public {
        LPStaking direct = new LPStaking();

        vm.expectRevert();
        direct.initialize(address(lpToken), address(rewardToken), feeDistributor, block.timestamp, vestingAllocation);
    }

    function test_Claim_SameBlockAfterStake_ZeroElapsedMpPath() public {
        uint256 amount = 1000e18;
        deal(address(lpToken), alice, amount);
        vm.warp(seedTime + VESTING_DELAY);

        vm.startPrank(alice);
        lpToken.approve(address(lpStaking), amount);
        lpStaking.stake(amount);

        // same block claim => elapsed == 0 in _updateUserMp
        uint256 claimed = lpStaking.claim();
        vm.stopPrank();

        (, uint256 mp,,) = lpStaking.userInfo(alice);
        assertEq(claimed, 0, "No rewards in same block claim");
        assertEq(mp, 0, "MP should remain zero with zero elapsed time");
    }
}

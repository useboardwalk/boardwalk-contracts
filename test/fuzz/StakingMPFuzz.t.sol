// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LPStaking} from "src/core/LPStaking.sol";

/// @dev Mock ERC20
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

/// @title StakingMPFuzzTest
/// @notice Fuzz tests for multiplier point precision over long time periods
///         Covers plan edge case #6
contract StakingMPFuzzTest is Test {
    LPStaking internal template;
    LPStaking internal staking;
    MockERC20 internal lpToken;
    MockERC20 internal rewardToken;
    address internal feeDistributor;
    address internal alice;

    uint256 internal constant VESTING_ALLOCATION = 1_000_000e18;

    function setUp() public {
        alice = makeAddr("alice");
        feeDistributor = makeAddr("feeDistributor");
        lpToken = new MockERC20("LP", "LP");
        rewardToken = new MockERC20("RWD", "RWD");

        template = new LPStaking();
        address clone = Clones.clone(address(template));
        staking = LPStaking(clone);

        staking.setInitializer(address(this));
        staking.initialize(address(lpToken), address(rewardToken), feeDistributor, block.timestamp, VESTING_ALLOCATION);
        rewardToken.mint(address(staking), VESTING_ALLOCATION);

        vm.warp(block.timestamp + 24 hours + 1);
    }

    // ============ Edge Case #6: MP Precision Over 3 Years ============

    function testFuzz_MPAccrual_MatchesExpected(
        uint256 stakeAmount,
        uint256 timeElapsed
    ) public {
        stakeAmount = bound(stakeAmount, 1e18, 1_000_000e18);
        timeElapsed = bound(timeElapsed, 1 days, 3 * 365 days);

        lpToken.mint(alice, stakeAmount);
        vm.startPrank(alice);
        lpToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + timeElapsed);

        // Trigger MP update
        vm.prank(alice);
        staking.claim();

        (, uint256 mp,,) = staking.userInfo(alice);
        // Expected: stakeAmount * timeElapsed * MP_RATE_BPS / 10000 / 365 days
        // MP_RATE_BPS = 10000 (100% APR)
        uint256 expectedMP = stakeAmount * timeElapsed / 365 days;

        // Allow 0.1% tolerance for rounding
        assertApproxEqRel(mp, expectedMP, 0.001e18, "MP accrual precision over time");
    }

    // ============ MP Proportional Burn Precision ============

    function testFuzz_MPBurn_Proportional(
        uint256 stakeAmount,
        uint256 withdrawPercent
    ) public {
        stakeAmount = bound(stakeAmount, 1000e18, 1_000_000e18);
        withdrawPercent = bound(withdrawPercent, 10, 90); // 10-90%

        lpToken.mint(alice, stakeAmount);
        vm.startPrank(alice);
        lpToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        // Accrue MP for 1 year
        vm.warp(block.timestamp + 365 days);

        // Withdraw percentage
        uint256 withdrawAmount = stakeAmount * withdrawPercent / 100;
        uint256 remainingLP = stakeAmount - withdrawAmount;

        vm.prank(alice);
        staking.withdraw(withdrawAmount);

        (uint256 lpAfter, uint256 mpAfter,,) = staking.userInfo(alice);
        assertEq(lpAfter, remainingLP, "LP remaining mismatch");

        // MP should be proportional to remaining LP
        // After 1 year at 100% APR, total MP ≈ stakeAmount
        // After withdrawing X%, remaining MP ≈ remainingLP
        uint256 expectedMP = remainingLP; // ~100% APR for 1 year = 1:1
        assertApproxEqRel(mpAfter, expectedMP, 0.005e18, "MP should be proportional after withdrawal");
    }

    // ============ Two Users: MP Doesn't Create Insolvency ============

    function testFuzz_TwoUsers_NoInsolvency(
        uint256 amount1,
        uint256 amount2,
        uint256 timeBetween
    ) public {
        amount1 = bound(amount1, 100e18, 100_000e18);
        amount2 = bound(amount2, 100e18, 100_000e18);
        timeBetween = bound(timeBetween, 1 hours, 180 days);

        // Alice stakes first
        lpToken.mint(alice, amount1);
        vm.startPrank(alice);
        lpToken.approve(address(staking), amount1);
        staking.stake(amount1);
        vm.stopPrank();

        // Warp
        vm.warp(block.timestamp + timeBetween);

        // Bob stakes
        address bob = makeAddr("bob");
        lpToken.mint(bob, amount2);
        vm.startPrank(bob);
        lpToken.approve(address(staking), amount2);
        staking.stake(amount2);
        vm.stopPrank();

        // Warp more
        vm.warp(block.timestamp + timeBetween);

        // Both claim - should not revert (solvency)
        vm.prank(alice);
        uint256 aliceClaimed = staking.claim();

        vm.prank(bob);
        uint256 bobClaimed = staking.claim();

        // Total claimed should be <= total rewards available
        uint256 totalClaimed = aliceClaimed + bobClaimed;
        assertGt(totalClaimed, 0, "Should have claimed rewards");

        // Contract solvency: total claimed must not exceed total input
        assertLe(totalClaimed, VESTING_ALLOCATION, "Claims must not exceed vesting allocation");

        // After claims, pending should be minimal (no double-counting)
        uint256 alicePending = staking.pendingRewards(alice);
        uint256 bobPending = staking.pendingRewards(bob);
        uint256 balance = rewardToken.balanceOf(address(staking));
        // Balance must cover remaining pending
        assertGe(balance, alicePending + bobPending, "Balance must cover pending rewards");
    }

    // ============ Missing Property: claim() matches pendingRewards() ============

    function testFuzz_Claim_MatchesPendingRewards(
        uint256 stakeAmount,
        uint256 timeElapsed
    ) public {
        stakeAmount = bound(stakeAmount, 1e18, 100_000e18);
        timeElapsed = bound(timeElapsed, 1 days, 365 days);

        lpToken.mint(alice, stakeAmount);
        vm.startPrank(alice);
        lpToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + timeElapsed);

        uint256 pending = staking.pendingRewards(alice);
        vm.prank(alice);
        uint256 claimed = staking.claim();

        assertEq(claimed, pending, "claim() should return same as pendingRewards()");
    }

    // ============ Missing Property: Full withdrawal leaves 0 LP ============

    function testFuzz_FullWithdrawal_LeavesZeroLP(
        uint256 stakeAmount
    ) public {
        stakeAmount = bound(stakeAmount, 1e18, 100_000e18);

        lpToken.mint(alice, stakeAmount);
        vm.startPrank(alice);
        lpToken.approve(address(staking), stakeAmount);
        staking.stake(stakeAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        vm.prank(alice);
        staking.withdraw(stakeAmount);

        (uint256 lpAfter, uint256 mpAfter,,) = staking.userInfo(alice);
        assertEq(lpAfter, 0, "Full withdrawal should leave 0 LP");
        assertEq(mpAfter, 0, "Full withdrawal should burn all MP");
    }
}

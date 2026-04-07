// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IntegrationBase, MockERC20, LaunchFactory} from "../integration/IntegrationBase.t.sol";
import {PresaleManager} from "src/core/PresaleManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PresaleContributionFuzzTest
/// @notice Fuzz tests for presale contribution precision and bonus normalization
///         Covers plan edge cases: #10, #15, #32
contract PresaleContributionFuzzTest is IntegrationBase {
    // ============ Edge Case #10: Many Small vs One Large Contribution ============

    function testFuzz_ManySmallVsOneLarge(
        uint256 largeAmount,
        uint8 numSmall
    ) public {
        largeAmount = bound(largeAmount, 0.1 ether, 100 ether);
        numSmall = uint8(bound(numSmall, 1, 20));
        uint256 smallAmount = largeAmount / numSmall;

        // Launch 1: one large contribution
        address token1 = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info1 = _getLaunchInfo(token1);

        _contribute(info1.presaleManager, alice, largeAmount);

        // Launch 2: many small contributions from same user
        address token2 = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info2 = _getLaunchInfo(token2);

        for (uint256 i = 0; i < numSmall; i++) {
            _contribute(info2.presaleManager, alice, smallAmount);
        }

        // Total contributions should be equal (within rounding)
        (uint256 total1, uint256 weighted1) = PresaleManager(info1.presaleManager).contributions(alice);
        (uint256 total2, uint256 weighted2) = PresaleManager(info2.presaleManager).contributions(alice);

        assertEq(total1, largeAmount, "Large contribution total mismatch");
        assertApproxEqAbs(total2, largeAmount, numSmall, "Small contributions should sum to large");
        // Also verify weighted amounts are consistent (both at t=0, same bonus)
        assertApproxEqAbs(weighted1, weighted2, numSmall * 2, "Weighted amounts should be approximately equal");
    }

    // ============ Edge Case #15: Token Allocation Sums to Presale Allocation ============

    function testFuzz_TokenAllocationConsistency(
        uint256 contrib1,
        uint256 contrib2,
        uint256 contrib3
    ) public {
        // Include small amounts, use vm.assume for graduation threshold
        contrib1 = bound(contrib1, 0.01 ether, 50 ether);
        contrib2 = bound(contrib2, 0.01 ether, 50 ether);
        contrib3 = bound(contrib3, 0.01 ether, 50 ether);
        vm.assume(contrib1 + contrib2 + contrib3 >= 10 ether); // Graduation threshold

        address tokenAddr = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);

        _contribute(info.presaleManager, alice, contrib1);
        _contribute(info.presaleManager, bob, contrib2);
        _contribute(info.presaleManager, charlie, contrib3);

        // Seed
        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);
        PresaleManager(info.presaleManager).seedLiquidity();

        // Calculate expected tokens
        uint256 aliceTokens = PresaleManager(info.presaleManager).calculateTokens(alice);
        uint256 bobTokens = PresaleManager(info.presaleManager).calculateTokens(bob);
        uint256 charlieTokens = PresaleManager(info.presaleManager).calculateTokens(charlie);

        uint256 totalTokens = aliceTokens + bobTokens + charlieTokens;
        uint256 presaleTokens = 10_000_000_000e18 * 5000 / 10000; // TOTAL_SUPPLY * 50% for Express

        // Sum of all token allocations should be <= presaleTokens (rounding dust only)
        assertLe(totalTokens, presaleTokens, "Total tokens should not exceed presale allocation");
        // Should be very close (within 3 wei of rounding per user)
        assertGe(totalTokens, presaleTokens - 3, "Rounding dust should be minimal");
    }

    // ============ Edge Case #32: Per-User WeightedWeth Accuracy ============

    function testFuzz_WeightedWethAccuracy(
        uint256 amount1,
        uint256 amount2,
        uint256 timeOffsetBps
    ) public {
        amount1 = bound(amount1, 0.01 ether, 100 ether);
        amount2 = bound(amount2, 0.01 ether, 100 ether);
        timeOffsetBps = bound(timeOffsetBps, 100, 9900); // 1% to 99% through presale

        address tokenAddr = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);

        // First contribution at t=0 (max bonus)
        _contribute(info.presaleManager, alice, amount1);

        // Second contribution at fuzzed time offset
        uint256 presaleStart = PresaleManager(info.presaleManager).presaleStart();
        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        uint256 duration = presaleEnd - presaleStart;
        vm.warp(presaleStart + (duration * timeOffsetBps / 10000));

        // Second contribution (less bonus)
        _contribute(info.presaleManager, bob, amount2);

        (uint256 aliceTotal, uint256 aliceWeighted) = PresaleManager(info.presaleManager).contributions(alice);
        (uint256 bobTotal, uint256 bobWeighted) = PresaleManager(info.presaleManager).contributions(bob);

        // Alice contributed earlier → higher weighted amount
        assertEq(aliceTotal, amount1, "Alice total mismatch");
        assertEq(bobTotal, amount2, "Bob total mismatch");
        // Weighted should be >= total (bonus multiplier >= 1.0)
        assertGe(aliceWeighted, aliceTotal, "Alice weighted should include bonus");
        assertGe(bobWeighted, bobTotal, "Bob weighted should include bonus");
        // Alice's per-unit weight should be >= Bob's (earlier = more bonus)
        assertGe(
            aliceWeighted * amount2, bobWeighted * amount1, "Earlier contributor should have higher per-unit weight"
        );
    }
}

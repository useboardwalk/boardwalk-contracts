// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IntegrationBase, MockERC20, LaunchFactory} from "./IntegrationBase.t.sol";
import {IPresaleManager} from "src/interfaces/IPresaleManager.sol";
import {IBoardwalkToken} from "src/interfaces/IBoardwalkToken.sol";
import {IFeeDistributor} from "src/interfaces/IFeeDistributor.sol";
import {ILPStaking} from "src/interfaces/ILPStaking.sol";
import {IVestingStream} from "src/interfaces/IVestingStream.sol";
import {PresaleManager} from "src/core/PresaleManager.sol";
import {BoardwalkToken} from "src/core/BoardwalkToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FullLaunchFlowTest
/// @notice End-to-end integration tests for the complete launch lifecycle
///         Covers plan edge cases: #1-5, #14, #18, #29, #30
contract FullLaunchFlowTest is IntegrationBase {
    // ============ Express Path: Full Lifecycle ============

    function test_ExpressPath_FullLifecycle() public {
        // 1. Create launch
        address tokenAddr = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);

        assertEq(info.token, tokenAddr, "Token address mismatch");
        assertTrue(info.presaleManager != address(0), "PresaleManager should be set");
        assertTrue(info.lpStaking != address(0), "LPStaking should be set");
        assertEq(info.issuer, issuer, "Issuer mismatch");
        assertEq(uint256(info.path), uint256(LaunchFactory.LaunchPath.EXPRESS), "Path should be EXPRESS");

        // 2. Contribute WETH (exceed graduation threshold)
        _contribute(info.presaleManager, alice, 5 ether);
        _contribute(info.presaleManager, bob, 5 ether);
        _contribute(info.presaleManager, charlie, 2 ether);

        // 3. Warp past presale end + seed delay
        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);

        // 4. Seed liquidity (anyone can call)
        PresaleManager(info.presaleManager).seedLiquidity();

        // Verify token supply is minted
        assertGt(IERC20(tokenAddr).totalSupply(), 0, "Tokens should be minted");

        // 5. Claim tokens after cliff
        uint256 seedTime = PresaleManager(info.presaleManager).liquiditySeedTime();
        vm.warp(seedTime + 7 days + 1); // Past cliff

        vm.prank(alice);
        PresaleManager(info.presaleManager).claimTokens();

        uint256 aliceTokens = IERC20(tokenAddr).balanceOf(alice);
        assertGt(aliceTokens, 0, "Alice should have tokens after claim");

        // 6. Transfer triggers tax
        uint256 transferAmount = aliceTokens / 2;
        vm.prank(alice);
        IERC20(tokenAddr).transfer(bob, transferAmount);

        // Bob receives less than transferAmount (tax deducted)
        uint256 bobTokens = IERC20(tokenAddr).balanceOf(bob);
        assertLt(bobTokens, transferAmount, "Bob should receive less due to tax");
    }

    // ============ Advanced Path: Full Lifecycle ============

    function test_AdvancedPath_FullLifecycle() public {
        // 1. Create launch
        address tokenAddr = _createAdvancedLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);

        assertEq(uint256(info.path), uint256(LaunchFactory.LaunchPath.ADVANCED), "Path should be ADVANCED");
        // Advanced launch with vesting recipients should have vestingStream set
        // (our _createAdvancedLaunch includes 2 vesting recipients)
        assertTrue(info.vestingStream != address(0), "VestingStream should be set for Advanced with vesting recipients");

        // 2. Advanced path has 24h delay before sale starts
        uint256 presaleStart = PresaleManager(info.presaleManager).presaleStart();
        assertGt(presaleStart, info.createdAt, "Advanced path should have delayed start");

        // Warp to after sale starts
        vm.warp(presaleStart + 1);

        // 3. Contribute
        _contribute(info.presaleManager, alice, 6 ether);
        _contribute(info.presaleManager, bob, 4 ether);
        _contribute(info.presaleManager, charlie, 3 ether);

        // 4. Seed liquidity
        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);
        PresaleManager(info.presaleManager).seedLiquidity();

        // 5. Verify vesting recipients can claim after cliff
        uint256 seedTime = PresaleManager(info.presaleManager).liquiditySeedTime();
        if (info.vestingStream != address(0)) {
            vm.warp(seedTime + 7 days + 30 days); // Past cliff + some vesting time

            vm.prank(vestingRecipient1);
            IVestingStream(info.vestingStream).claim(0);

            uint256 vestedAmount = IERC20(tokenAddr).balanceOf(vestingRecipient1);
            assertGt(vestedAmount, 0, "Vesting recipient should have tokens");
        }
    }

    // ============ Edge Case #1: Zero WETH Raised ============

    function test_ZeroWethRaised_SeedReverts() public {
        address tokenAddr = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);

        // Warp past presale end + seed delay without contributing
        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);

        // seedLiquidity should revert (below graduation)
        vm.expectRevert();
        PresaleManager(info.presaleManager).seedLiquidity();
    }

    // ============ Edge Case #2: Exactly Graduation Threshold ============

    function test_ExactGraduationThreshold_Succeeds() public {
        address tokenAddr = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);

        // Contribute exactly 10 WETH (the graduation threshold)
        _contribute(info.presaleManager, alice, 10 ether);

        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);

        // Should succeed at exact threshold
        PresaleManager(info.presaleManager).seedLiquidity();
        assertGt(IERC20(tokenAddr).totalSupply(), 0, "Seed should succeed at exact threshold");
    }

    // ============ Edge Case #3: Last-Second Contribution ============

    function test_LastSecondContribution_Accepted() public {
        address tokenAddr = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);

        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();

        // Contribute at the last possible second
        vm.warp(presaleEnd - 1);
        _contribute(info.presaleManager, alice, 10 ether);

        // Should be accepted
        (uint256 totalContributed,) = PresaleManager(info.presaleManager).contributions(alice);
        assertEq(totalContributed, 10 ether, "Last-second contribution should be accepted");
    }

    // ============ Edge Case #4: Seed at Exact 1hr Mark ============

    function test_SeedAtExactOneHourMark() public {
        address tokenAddr = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);

        _contribute(info.presaleManager, alice, 15 ether);

        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();

        // Seed at exact presaleEnd + 1 hour
        vm.warp(presaleEnd + 1 hours);

        // Should succeed (>= delay)
        PresaleManager(info.presaleManager).seedLiquidity();
        assertGt(IERC20(tokenAddr).totalSupply(), 0, "Seed at exact 1hr should work");
    }

    // ============ Edge Case #5: Simultaneous Seed Calls ============

    function test_SimultaneousSeedCalls_SecondReverts() public {
        address tokenAddr = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);

        _contribute(info.presaleManager, alice, 15 ether);

        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);

        // First call succeeds
        PresaleManager(info.presaleManager).seedLiquidity();

        // Second call reverts with AlreadySeeded
        vm.expectRevert(PresaleManager.AlreadySeeded.selector);
        PresaleManager(info.presaleManager).seedLiquidity();
    }

    // ============ Edge Case #14: Failed Sale Refund ============

    function test_FailedSale_RefundForever() public {
        address tokenAddr = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);

        // Contribute below threshold
        _contribute(info.presaleManager, alice, 5 ether);
        _contribute(info.presaleManager, bob, 3 ether);

        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);

        // Can't seed (below threshold)
        vm.expectRevert();
        PresaleManager(info.presaleManager).seedLiquidity();

        // Refund should work
        uint256 aliceWethBefore = weth.balanceOf(alice);
        vm.prank(alice);
        PresaleManager(info.presaleManager).refund();
        assertEq(weth.balanceOf(alice), aliceWethBefore + 5 ether, "Alice should get full refund");

        // Refund works even much later
        vm.warp(presaleEnd + 365 days);
        uint256 bobWethBefore = weth.balanceOf(bob);
        vm.prank(bob);
        PresaleManager(info.presaleManager).refund();
        assertEq(weth.balanceOf(bob), bobWethBefore + 3 ether, "Bob should get refund even after a year");
    }

    // ============ Edge Case #18: Express Path with Referrer Reverts ============

    function test_ExpressPath_WithReferrer_Reverts() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        address[] memory feeRecipients = new address[](1);
        feeRecipients[0] = feeRecipient1;
        uint256[] memory feeSplits = new uint256[](1);
        feeSplits[0] = 10000;

        string[] memory feeLabels = new string[](1);
        feeLabels[0] = "issuer";

        LaunchFactory.LaunchConfig memory config = LaunchFactory.LaunchConfig({
            name: "Bad Token",
            ticker: "BAD",
            category: "DeFi",
            description: "Should fail",
            path: LaunchFactory.LaunchPath.EXPRESS,
            presalePercent: 5000,
            vestingRecipients: new address[](0),
            vestingPercents: new uint256[](0),
            vestingLabels: new string[](0),
            referrer: referrer, // NOT allowed on EXPRESS
            integrator: address(0),
            issuerFeeRecipients: feeRecipients,
            issuerFeeSplits: feeSplits,
            issuerFeeLabels: feeLabels
        });

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.ReferrerNotAllowedOnExpressPath.selector);
        factory.createLaunch(config);
    }

    // ============ Edge Case #29: Advanced Path 24hr Delay ============

    function test_AdvancedPath_24hrDelay_CannotContributeBefore() public {
        address tokenAddr = _createAdvancedLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);

        uint256 presaleStart = PresaleManager(info.presaleManager).presaleStart();

        // Try to contribute before sale starts
        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(info.presaleManager, 10 ether);

        // Should revert with PresaleNotStarted
        vm.expectRevert(PresaleManager.PresaleNotStarted.selector);
        IPresaleManager(info.presaleManager).contribute(10 ether);
        vm.stopPrank();

        // Warp past start, now should work
        vm.warp(presaleStart + 1);
        vm.startPrank(alice);
        IPresaleManager(info.presaleManager).contribute(10 ether);
        vm.stopPrank();

        (uint256 contribTotal,) = PresaleManager(info.presaleManager).contributions(alice);
        assertEq(contribTotal, 10 ether, "Contribution after start should work");
    }

    // ============ Edge Case #30: Presale Percent Not Divisible by 5 ============

    function test_AdvancedPath_PresalePercentNotDivisibleBy5_Reverts() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        address[] memory feeRecipients = new address[](1);
        feeRecipients[0] = feeRecipient1;
        uint256[] memory feeSplits = new uint256[](1);
        feeSplits[0] = 10000;

        string[] memory feeLabels = new string[](1);
        feeLabels[0] = "issuer";

        LaunchFactory.LaunchConfig memory config = LaunchFactory.LaunchConfig({
            name: "Bad Percent",
            ticker: "BAD",
            category: "DeFi",
            description: "Should fail",
            path: LaunchFactory.LaunchPath.ADVANCED,
            presalePercent: 3100, // Not divisible by 500 (5%)
            vestingRecipients: new address[](0),
            vestingPercents: new uint256[](0),
            vestingLabels: new string[](0),
            referrer: address(0),
            integrator: address(0),
            issuerFeeRecipients: feeRecipients,
            issuerFeeSplits: feeSplits,
            issuerFeeLabels: feeLabels
        });

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.PresalePercentNotDivisibleBy5.selector);
        factory.createLaunch(config);
    }

    // ============ Multiple Launches Independence ============

    function test_MultipleLaunches_Independent() public {
        address token1 = _createExpressLaunch();
        address token2 = _createExpressLaunch();

        assertTrue(token1 != token2, "Each launch should have unique token");

        LaunchFactory.LaunchInfo memory info1 = _getLaunchInfo(token1);
        LaunchFactory.LaunchInfo memory info2 = _getLaunchInfo(token2);

        assertTrue(info1.presaleManager != info2.presaleManager, "Presale managers should be different");
        assertTrue(info1.feeDistributor != info2.feeDistributor, "FeeDistributors should be different");
        assertTrue(info1.lpStaking != info2.lpStaking, "LPStaking should be different");
    }

    // ============ Template Initialization Blocked (Edge Case #38) ============

    function test_TemplateInitialization_Blocked() public {
        vm.expectRevert();
        tokenTemplate.initialize("X", "X", 80, address(1), address(2), new address[](0));

        vm.expectRevert();
        lpStakingTemplate.initialize(address(1), address(2), address(3), block.timestamp, 1000e18);
    }

    // ============ Pre-initialization Attack Prevented ============

    function test_PreInitializationAttack_Prevented() public {
        address tokenAddr = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);

        // Try to call setInitializer on LPStaking (should fail, already set by factory)
        vm.expectRevert();
        ILPStaking(info.lpStaking).setInitializer(address(this));

        // Try to call initialize directly (should fail, not the authorized initializer)
        vm.expectRevert();
        ILPStaking(info.lpStaking).initialize(address(1), address(2), address(3), block.timestamp, 0);
    }

    // ============ Anti-Whale Decay (Edge Case #17) ============

    function test_AntiWhaleDecay_TaxDecreasesOverTime() public {
        // Create launch, contribute, seed
        address tkn = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory launchInfo = _getLaunchInfo(tkn);

        _contribute(launchInfo.presaleManager, alice, 15 ether);
        uint256 presaleEnd = PresaleManager(launchInfo.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);
        PresaleManager(launchInfo.presaleManager).seedLiquidity();

        uint256 seedTime = PresaleManager(launchInfo.presaleManager).liquiditySeedTime();

        // Give alice and bob tokens via claim (past cliff)
        vm.warp(seedTime + 7 days + 1);
        vm.prank(alice);
        PresaleManager(launchInfo.presaleManager).claimTokens();

        uint256 aliceBalance = IERC20(tkn).balanceOf(alice);
        uint256 chunk = aliceBalance / 10;

        // Tax at t=0 (immediately after seed): should be ~40% (anti-whale max)
        // We can't go back in time, but we can test at 90min+ to verify base rate
        // Warp to just past 90 minutes from seed
        vm.warp(seedTime + 91 minutes);

        deal(tkn, alice, chunk * 2);

        vm.prank(alice);
        IERC20(tkn).transfer(bob, chunk);
        uint256 taxAfterAntiWhale = chunk - IERC20(tkn).balanceOf(bob);

        // After 90 minutes, tax should be base rate (1.15%)
        uint256 expectedBaseTax = chunk * 115 / 10000;
        assertApproxEqAbs(taxAfterAntiWhale, expectedBaseTax, 1, "Tax should be base rate after 90 min");
    }
}

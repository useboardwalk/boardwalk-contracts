// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    IntegrationBase,
    MockERC20,
    MockPair,
    MockDEXFactory,
    LaunchFactory
} from "../integration/IntegrationBase.t.sol";
import {PresaleManager} from "src/core/PresaleManager.sol";
import {FeeDistributor} from "src/core/FeeDistributor.sol";
import {BoardwalkToken} from "src/core/BoardwalkToken.sol";
import {LPStaking} from "src/core/LPStaking.sol";
import {VestingStream} from "src/core/VestingStream.sol";
import {BoardwalkFeeCollector} from "src/core/BoardwalkFeeCollector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title GasBenchmarks
/// @notice Accurate gas benchmarks for all key Boardwalk operations.
///         Uses snapshotGasLastCall for precise callee-perspective gas measurement.
///         Must be run with --isolate flag for accuracy:
///         `forge test --match-contract GasBenchmarks --isolate`
///
/// @dev Snapshots are written to snapshots/GasBenchmarks.json
///      Each test is annotated with forge-config isolate for per-test isolation.
contract GasBenchmarks is IntegrationBase {
    // ============ State for seeded launches ============

    address internal expressToken;
    LaunchFactory.LaunchInfo internal expressInfo;

    address internal advancedToken;
    LaunchFactory.LaunchInfo internal advancedInfo;

    address internal pair;
    uint256 internal seedTime;

    // ========================================================================
    //  LAUNCH CREATION
    // ========================================================================

    /// forge-config: default.isolate = true
    function test_gas_createLaunch_Express() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();

        vm.prank(issuer);
        factory.createLaunch(config);
        vm.snapshotGasLastCall("createLaunch_Express");
    }

    /// forge-config: default.isolate = true
    function test_gas_createLaunch_Advanced() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();

        vm.prank(issuer);
        factory.createLaunch(config);
        vm.snapshotGasLastCall("createLaunch_Advanced");
    }

    // ========================================================================
    //  PRESALE CONTRIBUTIONS
    // ========================================================================

    /// forge-config: default.isolate = true
    function test_gas_contribute_First() public {
        address tkn = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tkn);

        weth.mint(alice, 5 ether);
        vm.startPrank(alice);
        weth.approve(info.presaleManager, 5 ether);

        PresaleManager(info.presaleManager).contribute(5 ether);
        vm.snapshotGasLastCall("contribute_First");
        vm.stopPrank();
    }

    /// forge-config: default.isolate = true
    function test_gas_contribute_Subsequent() public {
        address tkn = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tkn);

        // First contribution
        weth.mint(alice, 10 ether);
        vm.startPrank(alice);
        weth.approve(info.presaleManager, 10 ether);
        PresaleManager(info.presaleManager).contribute(5 ether);

        // Benchmark second contribution (cheaper, storage already warm)
        PresaleManager(info.presaleManager).contribute(5 ether);
        vm.snapshotGasLastCall("contribute_Subsequent");
        vm.stopPrank();
    }

    // ========================================================================
    //  SEED LIQUIDITY
    // ========================================================================

    /// forge-config: default.isolate = true
    function test_gas_seedLiquidity_Express() public {
        address tkn = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tkn);

        _contribute(info.presaleManager, alice, 10 ether);
        _contribute(info.presaleManager, bob, 5 ether);

        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);

        PresaleManager(info.presaleManager).seedLiquidity();
        vm.snapshotGasLastCall("seedLiquidity_Express");
    }

    /// forge-config: default.isolate = true
    function test_gas_seedLiquidity_Advanced() public {
        address tkn = _createAdvancedLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tkn);

        uint256 presaleStart = PresaleManager(info.presaleManager).presaleStart();
        vm.warp(presaleStart + 1);

        _contribute(info.presaleManager, alice, 10 ether);
        _contribute(info.presaleManager, bob, 5 ether);

        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);

        PresaleManager(info.presaleManager).seedLiquidity();
        vm.snapshotGasLastCall("seedLiquidity_Advanced");
    }

    // ========================================================================
    //  TOKEN CLAIMS
    // ========================================================================

    /// forge-config: default.isolate = true
    function test_gas_claimTokens() public {
        _setupSeededExpress();

        vm.warp(seedTime + 7 days + 1); // Past cliff

        vm.prank(alice);
        PresaleManager(expressInfo.presaleManager).claimTokens();
        vm.snapshotGasLastCall("claimTokens");
    }

    // ========================================================================
    //  REFUND (failed presale)
    // ========================================================================

    /// forge-config: default.isolate = true
    function test_gas_refund() public {
        address tkn = _createExpressLaunch();
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tkn);

        _contribute(info.presaleManager, alice, 5 ether); // Below 10 ETH threshold

        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);

        vm.prank(alice);
        PresaleManager(info.presaleManager).refund();
        vm.snapshotGasLastCall("refund");
    }

    // ========================================================================
    //  TAXED TRANSFER (includes onTaxReceived callback)
    // ========================================================================

    /// forge-config: default.isolate = true
    function test_gas_transfer_Taxed() public {
        _setupSeededExpress();
        vm.warp(seedTime + 7 days + 1);

        vm.prank(alice);
        PresaleManager(expressInfo.presaleManager).claimTokens();

        uint256 amount = IERC20(expressToken).balanceOf(alice) / 4;

        // Warp past anti-whale (90 min from seed)
        vm.warp(seedTime + 91 minutes);

        vm.prank(alice);
        IERC20(expressToken).transfer(bob, amount);
        vm.snapshotGasLastCall("transfer_Taxed");
    }

    /// forge-config: default.isolate = true
    /// @dev NOTE: This benchmark uses a time-warp back to seedTime+1 to hit the anti-whale
    ///      code path. This is not a reachable state in the real lifecycle (claims require 7-day cliff),
    ///      but accurately measures the gas cost of the anti-whale tax calculation branch.
    function test_gas_transfer_Taxed_AntiWhale() public {
        _setupSeededExpress();
        vm.warp(seedTime + 7 days + 1);

        vm.prank(alice);
        PresaleManager(expressInfo.presaleManager).claimTokens();

        uint256 amount = IERC20(expressToken).balanceOf(alice) / 4;

        // Warp back to anti-whale window (not reachable in production, gas-measurement only)
        vm.warp(seedTime + 1);

        vm.prank(alice);
        IERC20(expressToken).transfer(bob, amount);
        vm.snapshotGasLastCall("transfer_Taxed_AntiWhale");
    }

    /// forge-config: default.isolate = true
    function test_gas_transfer_Exempt_Pure() public {
        _setupSeededExpress();
        vm.warp(seedTime + 7 days + 1);

        // Claim first so alice has tokens
        vm.prank(alice);
        PresaleManager(expressInfo.presaleManager).claimTokens();

        uint256 amount = IERC20(expressToken).balanceOf(alice) / 4;

        // Transfer from alice (non-exempt) to FeeDistributor (exempt) — no tax applied
        // isExempt[to] == true → _calculateTax returns 0 → pure ERC20 balance update
        vm.prank(alice);
        IERC20(expressToken).transfer(expressInfo.feeDistributor, amount);
        vm.snapshotGasLastCall("transfer_Exempt_Pure");
    }

    /// forge-config: default.isolate = true
    /// @dev Taxed transfer that triggers epoch advancement inside notifyFees.
    ///      Uses advanced path with a staker so reward distribution runs the full
    ///      accumulator path (not the zero-staker shortcut).
    function test_gas_transfer_Taxed_EpochAdvance() public {
        _setupStakedAdvanced();

        // Warp past cliff so we can claim tokens
        vm.warp(seedTime + 7 days + 1);

        // Alice claims presale tokens
        vm.prank(alice);
        PresaleManager(advancedInfo.presaleManager).claimTokens();
        uint256 amount = IERC20(advancedToken).balanceOf(alice) / 4;

        // Warp past anti-whale AND past the first epoch boundary (7 days from seed)
        // seedTime + 7d + 1 is already past epoch end (epoch started at seedTime, duration 7d)
        // So the next taxed transfer will trigger epoch advancement in notifyFees

        vm.prank(alice);
        IERC20(advancedToken).transfer(bob, amount);
        vm.snapshotGasLastCall("transfer_Taxed_EpochAdvance");
    }

    // ========================================================================
    //  LP STAKING
    // ========================================================================

    /// forge-config: default.isolate = true
    function test_gas_lpStaking_Stake() public {
        _setupSeededAdvanced();

        MockPair(pair).mint(alice, 1000e18);

        vm.warp(seedTime + 24 hours + 1);

        vm.startPrank(alice);
        IERC20(pair).approve(advancedInfo.lpStaking, 1000e18);

        LPStaking(advancedInfo.lpStaking).stake(1000e18);
        vm.snapshotGasLastCall("lpStaking_Stake");
        vm.stopPrank();
    }

    /// forge-config: default.isolate = true
    function test_gas_lpStaking_Claim() public {
        _setupStakedAdvanced();

        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        LPStaking(advancedInfo.lpStaking).claim();
        vm.snapshotGasLastCall("lpStaking_Claim");
    }

    /// forge-config: default.isolate = true
    function test_gas_lpStaking_Withdraw() public {
        _setupStakedAdvanced();

        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        LPStaking(advancedInfo.lpStaking).withdraw(500e18);
        vm.snapshotGasLastCall("lpStaking_Withdraw");
    }

    /// forge-config: default.isolate = true
    function test_gas_lpStaking_NotifyFees() public {
        _setupStakedAdvanced();

        deal(advancedToken, advancedInfo.feeDistributor, 100e18);
        vm.startPrank(advancedInfo.feeDistributor);
        IERC20(advancedToken).approve(advancedInfo.lpStaking, 100e18);

        LPStaking(advancedInfo.lpStaking).notifyFees(100e18);
        vm.snapshotGasLastCall("lpStaking_NotifyFees");
        vm.stopPrank();
    }

    /// forge-config: default.isolate = true
    function test_gas_lpStaking_NotifyFees_EpochAdvance() public {
        _setupStakedAdvanced();

        // Add fees to pending
        deal(advancedToken, advancedInfo.feeDistributor, 200e18);
        vm.startPrank(advancedInfo.feeDistributor);
        IERC20(advancedToken).approve(advancedInfo.lpStaking, 200e18);
        LPStaking(advancedInfo.lpStaking).notifyFees(100e18);
        vm.stopPrank();

        // Warp past epoch end
        vm.warp(block.timestamp + 7 days + 1);

        // This notifyFees triggers epoch advance (more expensive)
        vm.prank(advancedInfo.feeDistributor);
        LPStaking(advancedInfo.lpStaking).notifyFees(100e18);
        vm.snapshotGasLastCall("lpStaking_NotifyFees_EpochAdvance");
    }

    // ========================================================================
    //  VESTING CLAIM
    // ========================================================================

    /// forge-config: default.isolate = true
    function test_gas_vestingStream_Claim() public {
        _setupSeededAdvanced();

        if (advancedInfo.vestingStream == address(0)) return;

        // Past cliff + some vesting time
        vm.warp(seedTime + 7 days + 30 days);

        vm.prank(vestingRecipient1);
        VestingStream(advancedInfo.vestingStream).claim(0);
        vm.snapshotGasLastCall("vestingStream_Claim");
    }

    // ========================================================================
    //  LP MANAGER (tax-exempt add/remove)
    // ========================================================================

    /// forge-config: default.isolate = true
    function test_gas_lpManager_AddLiquidity() public {
        _setupSeededExpress();

        uint256 tokenAmount = 1000e18;
        uint256 wethAmount = 1 ether;
        deal(expressToken, alice, tokenAmount);
        weth.mint(alice, wethAmount);

        vm.startPrank(alice);
        IERC20(expressToken).approve(address(lpManager), tokenAmount);
        weth.approve(address(lpManager), wethAmount);

        lpManager.addLiquidity(
            expressToken, address(weth), tokenAmount, wethAmount, 0, 0, alice, block.timestamp + 1 hours
        );
        vm.snapshotGasLastCall("lpManager_AddLiquidity");
        vm.stopPrank();
    }

    /// forge-config: default.isolate = true
    function test_gas_lpManager_RemoveLiquidity() public {
        _setupSeededExpress();

        // First add liquidity
        uint256 tokenAmount = 1000e18;
        uint256 wethAmount = 1 ether;
        deal(expressToken, alice, tokenAmount);
        weth.mint(alice, wethAmount);

        vm.startPrank(alice);
        IERC20(expressToken).approve(address(lpManager), tokenAmount);
        weth.approve(address(lpManager), wethAmount);
        (,, uint256 liquidity) = lpManager.addLiquidity(
            expressToken, address(weth), tokenAmount, wethAmount, 0, 0, alice, block.timestamp + 1 hours
        );
        vm.stopPrank();

        address pairAddr = dexFactory.getPair(expressToken, address(weth));

        vm.startPrank(alice);
        IERC20(pairAddr).approve(address(lpManager), liquidity);

        lpManager.removeLiquidity(expressToken, address(weth), liquidity, 0, 0, block.timestamp + 1 hours);
        vm.snapshotGasLastCall("lpManager_RemoveLiquidity");
        vm.stopPrank();
    }

    // ========================================================================
    //  FEE COLLECTOR
    // ========================================================================

    /// forge-config: default.isolate = true
    function test_gas_feeCollector_ReceiveFees() public {
        address tkn = address(new MockERC20("FeeToken", "FT"));
        MockERC20(tkn).mint(alice, 1000e18);

        vm.startPrank(alice);
        IERC20(tkn).approve(address(feeCollector), 1000e18);

        feeCollector.receiveFees(tkn, 1000e18);
        vm.snapshotGasLastCall("feeCollector_ReceiveFees");
        vm.stopPrank();
    }

    // ========================================================================
    //  HELPERS — Setup reusable seeded states
    // ========================================================================

    function _buildExpressConfig() internal view returns (LaunchFactory.LaunchConfig memory) {
        address[] memory feeRecipients = new address[](1);
        feeRecipients[0] = feeRecipient1;
        uint256[] memory feeSplits = new uint256[](1);
        feeSplits[0] = 10000;

        string[] memory feeLabels = new string[](1);
        feeLabels[0] = "issuer";

        return LaunchFactory.LaunchConfig({
            name: "Gas Test Token",
            ticker: "GAS",
            category: "DeFi",
            description: "Gas benchmark token",
            path: LaunchFactory.LaunchPath.EXPRESS,
            presalePercent: 5000,
            vestingRecipients: new address[](0),
            vestingPercents: new uint256[](0),
            vestingLabels: new string[](0),
            referrer: address(0),
            integrator: address(0),
            issuerFeeRecipients: feeRecipients,
            issuerFeeSplits: feeSplits,
            issuerFeeLabels: feeLabels
        });
    }

    function _buildAdvancedConfig() internal view returns (LaunchFactory.LaunchConfig memory) {
        address[] memory feeRecipients = new address[](2);
        feeRecipients[0] = feeRecipient1;
        feeRecipients[1] = feeRecipient2;
        uint256[] memory feeSplits = new uint256[](2);
        feeSplits[0] = 6000;
        feeSplits[1] = 4000;

        address[] memory vestRecipients = new address[](2);
        vestRecipients[0] = vestingRecipient1;
        vestRecipients[1] = vestingRecipient2;
        uint256[] memory vestPercents = new uint256[](2);
        vestPercents[0] = 7000;
        vestPercents[1] = 3000;

        string[] memory feeLabels = new string[](2);
        feeLabels[0] = "feeA";
        feeLabels[1] = "feeB";
        string[] memory vestLabels = new string[](2);
        vestLabels[0] = "v0";
        vestLabels[1] = "v1";

        return LaunchFactory.LaunchConfig({
            name: "Gas Advanced Token",
            ticker: "GADV",
            category: "DeFi",
            description: "Gas benchmark advanced",
            path: LaunchFactory.LaunchPath.ADVANCED,
            presalePercent: 3000,
            vestingRecipients: vestRecipients,
            vestingPercents: vestPercents,
            vestingLabels: vestLabels,
            referrer: referrer,
            integrator: address(0),
            issuerFeeRecipients: feeRecipients,
            issuerFeeSplits: feeSplits,
            issuerFeeLabels: feeLabels
        });
    }

    function _setupSeededExpress() internal {
        expressToken = _createExpressLaunch();
        expressInfo = _getLaunchInfo(expressToken);
        _contribute(expressInfo.presaleManager, alice, 10 ether);
        _contribute(expressInfo.presaleManager, bob, 5 ether);
        uint256 presaleEnd = PresaleManager(expressInfo.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);
        PresaleManager(expressInfo.presaleManager).seedLiquidity();
        seedTime = PresaleManager(expressInfo.presaleManager).liquiditySeedTime();
        pair = dexFactory.getPair(expressToken, address(weth));
    }

    function _setupSeededAdvanced() internal {
        advancedToken = _createAdvancedLaunch();
        advancedInfo = _getLaunchInfo(advancedToken);
        uint256 presaleStart = PresaleManager(advancedInfo.presaleManager).presaleStart();
        vm.warp(presaleStart + 1);
        _contribute(advancedInfo.presaleManager, alice, 10 ether);
        _contribute(advancedInfo.presaleManager, bob, 5 ether);
        uint256 presaleEnd = PresaleManager(advancedInfo.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);
        PresaleManager(advancedInfo.presaleManager).seedLiquidity();
        seedTime = PresaleManager(advancedInfo.presaleManager).liquiditySeedTime();
        pair = dexFactory.getPair(advancedToken, address(weth));
    }

    function _setupStakedAdvanced() internal {
        _setupSeededAdvanced();
        MockPair(pair).mint(alice, 1000e18);
        vm.warp(seedTime + 24 hours + 1);
        vm.startPrank(alice);
        IERC20(pair).approve(advancedInfo.lpStaking, 1000e18);
        LPStaking(advancedInfo.lpStaking).stake(1000e18);
        vm.stopPrank();
    }
}

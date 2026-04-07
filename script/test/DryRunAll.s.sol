// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IDEXRouter} from "src/interfaces/IDEXRouter.sol";
import {BoardwalkToken} from "src/core/BoardwalkToken.sol";
import {FeeDistributor} from "src/core/FeeDistributor.sol";
import {PresaleManager} from "src/core/PresaleManager.sol";
import {VestingStream} from "src/core/VestingStream.sol";
import {LPStaking} from "src/core/LPStaking.sol";
import {BoardwalkLPManager} from "src/core/BoardwalkLPManager.sol";
import {BoardwalkFeeCollector} from "src/core/BoardwalkFeeCollector.sol";
import {LaunchFactory} from "src/core/LaunchFactory.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {ParticipationDistributor} from "src/governance/ParticipationDistributor.sol";

/// @title DryRunAll - Combined dry-run of all 3 deployment scripts
/// @notice Deploys DEX → Factory → Governance in one transaction to validate the full pipeline
contract DryRunAll is Script {
    function run() public {
        address deployer = vm.envAddress("DEPLOYER");
        address owner = vm.envOr("OWNER", deployer);
        address weth = vm.envAddress("WETH_ADDRESS");
        address bmx = vm.envAddress("BMX_ADDRESS");
        address feeToSetter = vm.envOr("FEE_TO_SETTER", deployer);
        address treasury = vm.envOr("TREASURY", deployer);
        address keeper = vm.envAddress("KEEPER_ADDRESS");

        // Governance-specific
        address sbfBmx = vm.envAddress("SBF_BMX");
        address stakedBmxTracker = vm.envAddress("STAKED_BMX_TRACKER");
        address bnBmx = vm.envAddress("BN_BMX");
        address universalRouter = vm.envAddress("UNIVERSAL_ROUTER");
        address v4PositionManager = vm.envAddress("V4_POSITION_MANAGER");
        address fallbackTreasury = vm.envOr("FALLBACK_TREASURY", deployer);

        vm.startBroadcast(deployer);

        // ========== Phase 1: DEX ==========
        console.log("=== Phase 1: DEX ===");

        address dexFactory =
            vm.deployCode("src/dex/core/UniswapV2Factory.sol:UniswapV2Factory", abi.encode(feeToSetter));
        address dexRouter =
            vm.deployCode("src/dex/periphery/UniswapV2Router02.sol:UniswapV2Router02", abi.encode(dexFactory, weth));

        require(IDEXRouter(dexRouter).factory() == dexFactory, "Router-Factory mismatch");
        console.log("DEX Factory:", dexFactory);
        console.log("DEX Router:", dexRouter);

        // ========== Phase 2: Factory ==========
        console.log("\n=== Phase 2: Factory ===");

        BoardwalkToken tokenImpl = new BoardwalkToken();
        FeeDistributor feeDistributorImpl = new FeeDistributor();
        PresaleManager presaleImpl = new PresaleManager();
        VestingStream vestingImpl = new VestingStream();
        LPStaking lpStakingImpl = new LPStaking();

        BoardwalkLPManager lpManager = new BoardwalkLPManager(dexFactory, dexRouter, weth);
        console.log("BoardwalkLPManager:", address(lpManager));

        BoardwalkFeeCollector feeCollector = new BoardwalkFeeCollector(owner, weth, dexRouter, treasury, keeper);
        console.log("BoardwalkFeeCollector:", address(feeCollector));

        LaunchFactory.FeeBpsDefaults memory feeBps = LaunchFactory.FeeBpsDefaults({
            issuer: 40,
            boardwalk: 45,
            incentive: 30,
            referrer: 5,
            integrator: 0,
            total: 115
        });

        LaunchFactory factory = new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenImpl),
                feeDistributorImpl: address(feeDistributorImpl),
                presaleImpl: address(presaleImpl),
                vestingImpl: address(vestingImpl),
                lpStakingImpl: address(lpStakingImpl),
                bmx: bmx,
                raiseToken: weth,
                boardwalkRouter: dexRouter,
                boardwalkDexFactory: dexFactory,
                boardwalkLpManager: address(lpManager),
                boardwalkFeeCollector: address(feeCollector),
                bmxBurnAmount: 100e18,
                graduationExpress: 10 ether,
                graduationAdvanced: 10 ether,
                expressDuration: 24 hours,
                advancedDuration: 7 days,
                feeBps: feeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );
        console.log("LaunchFactory:", address(factory));

        // Verify factory wiring
        require(factory.TOKEN_IMPL() == address(tokenImpl), "tokenImpl mismatch");
        require(factory.RAISE_TOKEN() == weth, "RAISE_TOKEN mismatch");
        require(factory.BMX() == bmx, "BMX mismatch");
        require(factory.BOARDWALK_LP_MANAGER() == address(lpManager), "LPManager mismatch");
        require(factory.boardwalkFeeCollector() == address(feeCollector), "FeeCollector mismatch");
        console.log("Factory wiring verified");

        // ========== Phase 3: Governance ==========
        console.log("\n=== Phase 3: Governance ===");

        GovernanceVoter governanceVoter = new GovernanceVoter(
            owner,
            GovernanceVoter.DeployParams({
                sbfBmx: sbfBmx,
                stakedBmxTracker: stakedBmxTracker,
                bnBmx: bnBmx,
                bmx: bmx,
                weth: weth,
                universalRouter: universalRouter,
                v4PositionManager: v4PositionManager,
                treasury: treasury,
                fallbackTreasury: fallbackTreasury,
                epochZero: block.timestamp,
                epochDuration: 7 days,
                poolFee: 3000,
                poolTickSpacing: int24(60),
                poolHooks: address(0),
                keeper: keeper
            })
        );
        console.log("GovernanceVoter:", address(governanceVoter));

        // v4 pools use native ETH (address(0)), always currency0
        LPLocker lpLocker = new LPLocker(
            v4PositionManager,
            address(governanceVoter),
            address(0),
            bmx
        );
        console.log("LPLocker:", address(lpLocker));

        ParticipationDistributor participationDistributor = new ParticipationDistributor(
            bmx,
            address(governanceVoter)
        );
        console.log("ParticipationDistributor:", address(participationDistributor));

        // Wire peers
        governanceVoter.initializePeers(address(lpLocker), address(participationDistributor));
        console.log("Peers initialized successfully");

        // Verify governance wiring
        require(governanceVoter.lpLocker() == address(lpLocker), "lpLocker mismatch");
        require(governanceVoter.participationDistributor() == address(participationDistributor), "PD mismatch");
        require(governanceVoter.peersInitialized(), "peers not initialized");
        console.log("Governance wiring verified");

        vm.stopBroadcast();

        // ========== Summary ==========
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("DEX Factory:               ", dexFactory);
        console.log("DEX Router:                ", dexRouter);
        console.log("BoardwalkLPManager:        ", address(lpManager));
        console.log("BoardwalkFeeCollector:     ", address(feeCollector));
        console.log("LaunchFactory:             ", address(factory));
        console.log("GovernanceVoter:           ", address(governanceVoter));
        console.log("LPLocker:                  ", address(lpLocker));
        console.log("ParticipationDistributor:  ", address(participationDistributor));
        console.log("\nAll 3 phases deployed and verified successfully.");
    }
}

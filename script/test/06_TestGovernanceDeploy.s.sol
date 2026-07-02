// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTestScript} from "./BaseTestScript.s.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {ParticipationDistributor} from "src/governance/ParticipationDistributor.sol";

/// @title TestGovernanceDeploy - Deploy the governance stack for backend testing
/// @notice Deploys GovernanceVoter + LPLocker + ParticipationDistributor. Defaults target the legacy
///         Base/BMX addresses; override via env to test the live Arbitrum/BWS wiring (see
///         script/bws/02_DeployBwsGovernance.s.sol for the production variant).
///         Uses short epoch durations so backend devs can test the full lifecycle quickly.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY    — deployer key (becomes owner/keeper/treasury)
///
/// Optional env (defaults to the legacy Base/BMX mainnet addresses):
///   BMX_ADDRESS,
///   SBF_BMX, STAKED_BMX_TRACKER, BN_BMX, UNIVERSAL_ROUTER, V4_POSITION_MANAGER,
///   WETH_ADDRESS, EPOCH_DURATION (default 10 minutes),
///   TREASURY, FALLBACK_TREASURY, KEEPER (all default to deployer)
contract TestGovernanceDeployScript is BaseTestScript {
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant BASE_SBF_BMX = 0x38E5be3501687500E6338217276069d16178077E;
    address internal constant BASE_STAKED_BMX_TRACKER = 0x3085F25Cbb5F34531229077BAAC20B9ef2AE85CB;
    address internal constant BASE_BN_BMX = 0x10AB197551BAB91f8B218dC9730AE0e43d893Db2;
    address internal constant BASE_UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant BASE_V4_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant BASE_BMX = 0x548f93779fBC992010C07467cBaf329DD5F059B7;

    function _scriptName() internal pure override returns (string memory) {
        return "TestGovernanceDeployScript";
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address bmx = vm.envOr("BMX_ADDRESS", BASE_BMX);
        address sbfBmx = vm.envOr("SBF_BMX", BASE_SBF_BMX);
        address stakedBmxTracker = vm.envOr("STAKED_BMX_TRACKER", BASE_STAKED_BMX_TRACKER);
        address bnBmx = vm.envOr("BN_BMX", BASE_BN_BMX);
        address weth = vm.envOr("WETH_ADDRESS", BASE_WETH);
        address universalRouter = vm.envOr("UNIVERSAL_ROUTER", BASE_UNIVERSAL_ROUTER);
        address v4PositionManager = vm.envOr("V4_POSITION_MANAGER", BASE_V4_POSITION_MANAGER);
        uint256 epochDuration = vm.envOr("EPOCH_DURATION", uint256(3 hours)); // 7 days
        address treasury = vm.envOr("TREASURY", deployer);
        address fallbackTreasury = vm.envOr("FALLBACK_TREASURY", deployer);
        address keeper = vm.envAddress("KEEPER_ADDRESS");

        _initTxTracking();
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy GovernanceVoter
        GovernanceVoter governanceVoter = new GovernanceVoter(
            deployer,
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
                epochDuration: epochDuration,
                poolFee: uint24(vm.envOr("POOL_FEE", uint256(10_000))),
                poolTickSpacing: int24(int256(vm.envOr("POOL_TICK_SPACING", uint256(200)))),
                poolHooks: vm.envOr("POOL_HOOKS", address(0)),
                keeper: keeper
            })
        );
        _recordTx("Deploy GovernanceVoter");

        // 2. Deploy LPLocker — v4 pools use native ETH (address(0)), always currency0
        LPLocker lpLocker = new LPLocker(v4PositionManager, address(governanceVoter), address(0), bmx, deployer);
        _recordTx("Deploy LPLocker");

        // 3. Deploy ParticipationDistributor
        ParticipationDistributor participationDistributor = new ParticipationDistributor(bmx, address(governanceVoter));
        _recordTx("Deploy ParticipationDistributor");

        // 4. Wire peers (one-time, validates bidirectional references). The feeCollector in
        //    a test deployment defaults to the OWNER so the script can later call depositRevenue
        //    via the same EOA; override via FEE_COLLECTOR if testing a different wiring.
        address feeCollector_ = vm.envOr("FEE_COLLECTOR", deployer);
        governanceVoter.initializePeers(address(lpLocker), address(participationDistributor), feeCollector_);
        _recordTx("GovernanceVoter.initializePeers");

        vm.stopBroadcast();

        console.log("=== GOVERNANCE TEST DEPLOYMENT ===");
        console.log("GOVERNANCE_VOTER:", address(governanceVoter));
        console.log("LP_LOCKER:", address(lpLocker));
        console.log("PARTICIPATION_DISTRIBUTOR:", address(participationDistributor));
        console.log("EPOCH_DURATION:", epochDuration);
        console.log("EPOCH_ZERO:", governanceVoter.EPOCH_ZERO());
        console.log("TREASURY:", treasury);
        console.log("KEEPER:", keeper);
        console.log("");
        console.log("Voter must hold the sbf fee-tracker token to vote. Epoch duration:", epochDuration, "seconds.");
        console.log("Send WETH to GovernanceVoter to simulate governance revenue before finalizing.");
        console.log("Next: run 07_TestGovernanceVoteAndExecute.s.sol");

        _printTxSummary();
    }
}

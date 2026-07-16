// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTestScript} from "./BaseTestScript.s.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {ParticipationDistributor} from "src/governance/ParticipationDistributor.sol";

/// @title TestGovernanceDeploy - Deploy the governance stack for backend testing
/// @notice Deploys GovernanceVoter + LPLocker + ParticipationDistributor. Defaults target the live
///         Ethereum mainnet BWLK staking set; override via env for other wirings (see
///         script/bwlk/02_DeployBwlkGovernance.s.sol for the production variant).
///         Uses short epoch durations so backend devs can test the full lifecycle quickly.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY    — deployer key (becomes owner)
///   KEEPER_ADDRESS          — the voter keeper
///
/// Optional env (defaults to the live Ethereum mainnet BWLK addresses):
///   BWLK_ADDRESS,
///   SBF_BWLK, STAKED_BWLK_TRACKER, BN_BWLK, UNIVERSAL_ROUTER, V4_POSITION_MANAGER,
///   WETH_ADDRESS, EPOCH_DURATION (default 3 hours),
///   TREASURY, FALLBACK_TREASURY (both default to deployer)
contract TestGovernanceDeployScript is BaseTestScript {
    address internal constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ETH_SBF_BWLK = 0x35527F4C52F319527DB71FAfD1D310bE211Ad37a;
    address internal constant ETH_STAKED_BWLK_TRACKER = 0x3961F92c26724C9d61CED679540F35794d90c576;
    address internal constant ETH_BN_BWLK = 0x5821282f792E61843a0096F8eEEF32939bd6E46D;
    address internal constant ETH_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant ETH_V4_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant ETH_BWLK = 0xF9a352b7C7B62a852e5C8A64A455246Dd9596461;

    function _scriptName() internal pure override returns (string memory) {
        return "TestGovernanceDeployScript";
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address bwlk = vm.envOr("BWLK_ADDRESS", ETH_BWLK);
        address sbfBwlk = vm.envOr("SBF_BWLK", ETH_SBF_BWLK);
        address stakedBwlkTracker = vm.envOr("STAKED_BWLK_TRACKER", ETH_STAKED_BWLK_TRACKER);
        address bnBwlk = vm.envOr("BN_BWLK", ETH_BN_BWLK);
        address weth = vm.envOr("WETH_ADDRESS", ETH_WETH);
        address universalRouter = vm.envOr("UNIVERSAL_ROUTER", ETH_UNIVERSAL_ROUTER);
        address v4PositionManager = vm.envOr("V4_POSITION_MANAGER", ETH_V4_POSITION_MANAGER);
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
                sbfBwlk: sbfBwlk,
                stakedBwlkTracker: stakedBwlkTracker,
                bnBwlk: bnBwlk,
                bwlk: bwlk,
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
        LPLocker lpLocker = new LPLocker(v4PositionManager, address(governanceVoter), address(0), bwlk, deployer);
        _recordTx("Deploy LPLocker");

        // 3. Deploy ParticipationDistributor
        ParticipationDistributor participationDistributor = new ParticipationDistributor(bwlk, address(governanceVoter));
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

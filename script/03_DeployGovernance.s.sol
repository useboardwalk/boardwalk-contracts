// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {ParticipationDistributor} from "src/governance/ParticipationDistributor.sol";

/// @title DeployGovernance - Deploy the governance voting stack on Base
/// @notice Deploys GovernanceVoter first, then LPLocker and ParticipationDistributor pointing back,
///         then wires them via initializePeers().
///         After deployment, call BoardwalkFeeCollector.signalAction(ACTION_SET_GOVERNANCE_VAULT, ...)
///         followed by executeSetGovernanceVault after the 7-day timelock.
///
/// @dev Required env: DEPLOYER_PRIVATE_KEY, OWNER, KEEPER
contract DeployGovernance is Script {
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant BASE_SBF_BMX = 0x38E5be3501687500E6338217276069d16178077E;
    address internal constant BASE_STAKED_BMX_TRACKER = 0x3085F25Cbb5F34531229077BAAC20B9ef2AE85CB;
    address internal constant BASE_BN_BMX = 0x10AB197551BAB91f8B218dC9730AE0e43d893Db2;
    address internal constant BASE_UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address internal constant BASE_V4_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address internal constant BASE_BMX = 0x548f93779fBC992010C07467cBaf329DD5F059B7;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envOr("OWNER", vm.addr(deployerPrivateKey));

        address bmx = vm.envOr("BMX_ADDRESS", BASE_BMX);
        address sbfBmx = vm.envOr("SBF_BMX", BASE_SBF_BMX);
        address stakedBmxTracker = vm.envOr("STAKED_BMX_TRACKER", BASE_STAKED_BMX_TRACKER);
        address bnBmx = vm.envOr("BN_BMX", BASE_BN_BMX);
        address weth = vm.envOr("WETH_ADDRESS", BASE_WETH);
        address universalRouter = vm.envOr("UNIVERSAL_ROUTER", BASE_UNIVERSAL_ROUTER);
        address v4PositionManager = vm.envOr("V4_POSITION_MANAGER", BASE_V4_POSITION_MANAGER);
        address treasury = vm.envOr("TREASURY", owner);
        address fallbackTreasury = vm.envOr("FALLBACK_TREASURY", owner);

        uint256 epochZero = vm.envOr("EPOCH_ZERO", block.timestamp);
        uint256 epochDuration = vm.envOr("EPOCH_DURATION", uint256(7 days));

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy GovernanceVoter (without peer references — set via initializePeers later)
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
                epochZero: epochZero,
                epochDuration: epochDuration,
                poolFee: uint24(vm.envOr("POOL_FEE", uint256(10_000))),
                poolTickSpacing: int24(int256(vm.envOr("POOL_TICK_SPACING", uint256(200)))),
                poolHooks: vm.envOr("POOL_HOOKS", address(0)),
                keeper: vm.envAddress("KEEPER")
            })
        );
        console.log("GovernanceVoter deployed to:", address(governanceVoter));

        // 2. Deploy LPLocker — v4 pools use native ETH (address(0)), always currency0
        LPLocker lpLocker = new LPLocker(
            v4PositionManager,
            address(governanceVoter),
            address(0),
            bmx
        );
        console.log("LPLocker deployed to:", address(lpLocker));

        // 3. Deploy ParticipationDistributor pointing to GovernanceVoter
        ParticipationDistributor participationDistributor = new ParticipationDistributor(
            bmx,
            address(governanceVoter)
        );
        console.log("ParticipationDistributor deployed to:", address(participationDistributor));

        // 4. Wire peers (one-time, validates bidirectional references)
        governanceVoter.initializePeers(address(lpLocker), address(participationDistributor));
        console.log("Peers initialized successfully");

        console.log("");
        console.log("Next steps:");
        console.log("1. Call FeeCollector.signalAction(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(", address(governanceVoter), ")))");
        console.log("2. After 7-day timelock, call FeeCollector.executeSetGovernanceVault(...)");

        vm.stopBroadcast();
    }
}

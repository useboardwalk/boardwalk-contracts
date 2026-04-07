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
contract DeployGovernance is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address sbfBmx = vm.envAddress("SBF_BMX");
        address stakedBmxTracker = vm.envAddress("STAKED_BMX_TRACKER");
        address bnBmx = vm.envAddress("BN_BMX");
        address bmx = vm.envAddress("BMX_ADDRESS");
        address raiseToken = vm.envAddress("RAISE_TOKEN_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
        address universalRouter = vm.envAddress("UNIVERSAL_ROUTER");
        address v4PositionManager = vm.envAddress("V4_POSITION_MANAGER");
        address treasury = vm.envAddress("TREASURY");
        address fallbackTreasury = vm.envAddress("FALLBACK_TREASURY");

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
                poolFee: uint24(vm.envOr("POOL_FEE", uint256(3000))),
                poolTickSpacing: int24(int256(vm.envOr("POOL_TICK_SPACING", uint256(60)))),
                poolHooks: vm.envOr("POOL_HOOKS", address(0)),
                keeper: vm.envAddress("GOVERNANCE_KEEPER")
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

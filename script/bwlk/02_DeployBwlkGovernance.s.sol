// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {ParticipationDistributor} from "src/governance/ParticipationDistributor.sol";
import {EthereumConfig} from "./EthereumConfig.sol";

/// @title DeployBwlkGovernance - Deploy the Ethereum/BWLK governance stack
/// @notice Deploys the Ethereum mainnet BWLK governance stack: GovernanceVoter wired
///         to the redeployed BWLK trackers (sbfBWLK / stakedBWLK / bnBWLK), the BWLK token, mainnet
///         WETH + UniversalRouter + v4 PositionManager; then LPLocker (currency0 = native ETH,
///         currency1 = BWLK) with a renounceable registrar, and ParticipationDistributor; finally
///         initializePeers.
/// @dev POOL_HOOKS is left unset here. Governance deploys before the CCA launch, so the BWLK/ETH pool's
///      hook is unknown at this point. After the CCA `migrate()`, recover the hook from the
///      PoolManager `Initialize` event or `getPoolAndPositionInfo` on the locker-owned position (the
///      `Migrated` event's indexed key topic is only a hash) and call
///      `GovernanceVoter.setPoolHooks(hook)` once; execute() blocks the swap/LP options until then.
///
///      Required env: DEPLOYER_PRIVATE_KEY, BWLK_TOKEN, STAKED_BWLK_TRACKER, FEE_BWLK_TRACKER (sbfBWLK),
///      BN_BWLK, KEEPER, FEE_COLLECTOR, LP_REGISTRAR (must be non-zero: it registers the CCA-minted LP,
///      and a zero registrar would leave the launch position permanently unregisterable). Optional
///      env: OWNER (default deployer), TREASURY, FALLBACK_TREASURY, EPOCH_ZERO, EPOCH_DURATION,
///      POOL_FEE, POOL_TICK_SPACING, WETH_ADDRESS, UNIVERSAL_ROUTER, V4_POSITION_MANAGER.
contract DeployBwlkGovernance is Script {
    error WrongChain(uint256 chainId);
    error ZeroRegistrar();

    function run() public {
        if (block.chainid != EthereumConfig.ETHEREUM_CHAIN_ID) revert WrongChain(block.chainid);
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envOr("OWNER", vm.addr(deployerPrivateKey));

        address bwlk = vm.envAddress("BWLK_TOKEN");
        address stakedBwlkTracker = vm.envAddress("STAKED_BWLK_TRACKER");
        address feeBwlkTracker = vm.envAddress("FEE_BWLK_TRACKER"); // sbfBWLK
        address bnBwlk = vm.envAddress("BN_BWLK");

        address weth = vm.envOr("WETH_ADDRESS", EthereumConfig.ETH_WETH);
        address universalRouter = vm.envOr("UNIVERSAL_ROUTER", EthereumConfig.ETH_UNIVERSAL_ROUTER);
        address v4PositionManager = vm.envOr("V4_POSITION_MANAGER", EthereumConfig.ETH_POSITION_MANAGER);
        address treasury = vm.envOr("TREASURY", owner);
        address fallbackTreasury = vm.envOr("FALLBACK_TREASURY", owner);

        uint256 epochZero = vm.envOr("EPOCH_ZERO", block.timestamp);
        uint256 epochDuration = vm.envOr("EPOCH_DURATION", uint256(7 days));

        vm.startBroadcast(deployerPrivateKey);

        // 1. GovernanceVoter - POOL_HOOKS is address(0) here (set post-CCA via setPoolHooks).
        GovernanceVoter governanceVoter = new GovernanceVoter(
            owner,
            GovernanceVoter.DeployParams({
                sbfBwlk: feeBwlkTracker,
                stakedBwlkTracker: stakedBwlkTracker,
                bnBwlk: bnBwlk,
                bwlk: bwlk,
                weth: weth,
                universalRouter: universalRouter,
                v4PositionManager: v4PositionManager,
                treasury: treasury,
                fallbackTreasury: fallbackTreasury,
                epochZero: epochZero,
                epochDuration: epochDuration,
                poolFee: uint24(vm.envOr("POOL_FEE", uint256(EthereumConfig.POOL_FEE))),
                poolTickSpacing: int24(
                    int256(vm.envOr("POOL_TICK_SPACING", uint256(uint24(EthereumConfig.POOL_TICK_SPACING))))
                ),
                poolHooks: address(0),
                keeper: vm.envAddress("KEEPER")
            })
        );
        console.log("GovernanceVoter deployed to:", address(governanceVoter));

        // 2. LPLocker - v4 native ETH is currency0 (address(0)); BWLK is currency1. Registrar registers
        //    the CCA-minted LP then renounces; it is irrevocable by anyone else, so require it
        //    explicitly (a zero registrar would strand the launch position's fees forever).
        address lpRegistrar = vm.envAddress("LP_REGISTRAR");
        if (lpRegistrar == address(0)) revert ZeroRegistrar();
        LPLocker lpLocker = new LPLocker(v4PositionManager, address(governanceVoter), address(0), bwlk, lpRegistrar);
        console.log("LPLocker deployed to:", address(lpLocker));
        console.log("  registrar:", lpRegistrar);

        // 3. ParticipationDistributor distributes BWLK to prior-epoch voters.
        ParticipationDistributor participationDistributor = new ParticipationDistributor(bwlk, address(governanceVoter));
        console.log("ParticipationDistributor deployed to:", address(participationDistributor));

        // 4. Wire peers (one-time, validates bidirectional references). Revenue depositor is the
        //    old Ethereum BoardwalkFeeCollector.
        address feeCollector = vm.envAddress("FEE_COLLECTOR");
        governanceVoter.initializePeers(address(lpLocker), address(participationDistributor), feeCollector);
        console.log("Peers initialized (feeCollector =", feeCollector, ")");

        vm.stopBroadcast();

        console.log("");
        console.log("DEFERRED (post-CCA): recover the BWLK/ETH pool hook from the PoolManager Initialize");
        console.log("event or getPoolAndPositionInfo on the locker-owned position (the Migrated event's");
        console.log("indexed key topic is only a hash), then call GovernanceVoter.setPoolHooks(hook)");
        console.log("ONCE. execute() blocks the swap/LP options until then. POOL_FEE / POOL_TICK_SPACING");
        console.log("are immutable here and MUST equal the launch pool's fee tier + tick spacing.");
    }
}

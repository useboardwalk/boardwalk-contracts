// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {RevenueBridger} from "src/crosschain/RevenueBridger.sol";
import {BaseRevenueSwapper} from "src/crosschain/BaseRevenueSwapper.sol";
import {CrossChainConfig} from "script/CrossChainConfig.sol";

/// @title DeployRevenueBridging
/// @notice Deploys Boardwalk's cross-chain revenue bridging: the `BaseRevenueSwapper` on Base and a
///         generic `RevenueBridger` on every non-Base LiFi lane (Ethereum, Ink, Arbitrum, Katana,
///         Fraxtal).
/// @dev Deploy order:
///      1. Base: run this script, which deploys `BaseRevenueSwapper`. Record its address; every other
///         lane pins it as `BASE_DESTINATION`.
///      2. Each non-Base chain: rerun with BASE_DESTINATION set to the swapper from step 1.
///         ETH/Ink/Arbitrum deploy a pure Across V4 bridger; Katana a composed Symbiosis one; Fraxtal
///         a composed Glacis one. Fraxtal/Glacis charges a native (FRAX) fee, so the keeper holds FRAX
///         and attaches it as `msg.value` per `bridgeToBase` call (excess refunded).
///      3. Byte-verify every external address against on-chain code before broadcasting, and recompute
///         the facet selectors from LiFi source at this commit.
///      4. transferOwnership (2-step) of all deployed contracts to the multisig.
///      5. Use a separate key on a separate host for each role: the source `BoardwalkFeeCollector.keeper`
///         (accrual), each bridger's keeper (bridge), and the Base swapper keeper.
///      6. Repoint revenue: per chain, `BoardwalkFeeCollector.signal/executeSetTreasury` (7-day timelock)
///         to the deployed bridger so `forwardRevenue` routes revenue in.
///      7. Keep `governanceVault == address(0)` on all source chains; a set vault diverts 70% past the
///         bridger. Never call `executeSetGovernanceVault` there; alert on `GovernanceVaultUpdated`.
///         BWS-migration carve-out: Arbitrum becomes the governance home — at the migration cutover
///         its FeeCollector's vault is set to the BWS GovernanceVoter, and the Arbitrum lane is
///         retired (the bridger pins Base as destination, so a post-cutover Arbitrum lane would
///         ship the hub's own revenue away; the replacement mesh targets Arbitrum).
///      8. Accrual gating: don't call `forwardRevenue` until monitoring confirms the previous bridge
///         landed on Base. The 30/70 split lands when the Base FeeCollector runs its regular cycle.
///
///      Required env: KEEPER. Base also: FEE_COLLECTOR. Non-Base also: BASE_DESTINATION. Katana also:
///      RAISE_TOKEN. Optional: OWNER (default deployer), MAX_FEE_BPS, RAISE_TOKEN (ETH/Ink/Arbitrum
///      default to canonical WETH, Fraxtal to frxUSD).
contract DeployRevenueBridging is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address owner = vm.envOr("OWNER", deployer);
        address keeper = vm.envAddress("KEEPER");
        require(owner != address(0) && keeper != address(0), "owner/keeper required");

        uint256 chainId = block.chainid;
        console.log("=== Boardwalk Revenue Bridging Deployment ===");
        console.log("Chain id:", chainId);
        console.log("Deployer:", deployer);
        console.log("Owner:", owner);
        console.log("Keeper:", keeper);

        vm.startBroadcast(deployerPrivateKey);

        if (chainId == CrossChainConfig.CHAIN_BASE) {
            _deploySwapper(owner, keeper);
        } else {
            _deployLifiBridger(owner, keeper, chainId);
        }

        vm.stopBroadcast();
    }

    function _deploySwapper(
        address owner,
        address keeper
    ) internal {
        address allowanceHolder = CrossChainConfig.ZEROX_ALLOWANCE_HOLDER;
        address weth = CrossChainConfig.BASE_WETH;
        address feeCollector = vm.envAddress("FEE_COLLECTOR");

        require(allowanceHolder.code.length > 0, "AllowanceHolder: no code");
        require(weth.code.length > 0, "WETH: no code");
        require(feeCollector.code.length > 0, "FeeCollector: no code");

        BaseRevenueSwapper swapper = new BaseRevenueSwapper(owner, allowanceHolder, weth, feeCollector, keeper);
        console.log("BaseRevenueSwapper:", address(swapper));
        console.log("  -> set this as BASE_DESTINATION on every non-Base lane");
        console.log("  -> the swap leg is keeper-trusted (keeper supplies tokenIn + 0x calldata + minOut)");
    }

    function _deployLifiBridger(
        address owner,
        address keeper,
        uint256 chainId
    ) internal {
        address diamond = CrossChainConfig.lifiDiamond(chainId);
        require(diamond.code.length > 0, "diamond: no code");

        address baseDestination = vm.envAddress("BASE_DESTINATION");
        require(baseDestination.code.length > 0, "BASE_DESTINATION: no code");
        address raiseToken = vm.envOr("RAISE_TOKEN", _defaultRaiseToken(chainId));
        require(raiseToken != address(0), "RAISE_TOKEN required");
        require(raiseToken.code.length > 0, "RAISE_TOKEN: no code");

        bool hasSourceSwaps = CrossChainConfig.hasSourceSwaps(chainId);
        uint256 maxFeeBps = vm.envOr("MAX_FEE_BPS", CrossChainConfig.DEFAULT_MAX_FEE_BPS);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = CrossChainConfig.lifiSelector(chainId);

        RevenueBridger bridger = new RevenueBridger(
            owner,
            diamond,
            raiseToken,
            baseDestination,
            CrossChainConfig.BASE_WETH,
            keeper,
            hasSourceSwaps,
            maxFeeBps,
            selectors
        );
        console.log("RevenueBridger:", address(bridger));
        console.log("  diamond:", diamond);
        console.log("  raiseToken:", raiseToken);
        console.log("  hasSourceSwaps:", hasSourceSwaps);
        console.log("  maxFeeBps:", maxFeeBps);
        console.logBytes4(selectors[0]);
        if (!hasSourceSwaps) {
            console.log(
                "  NOTE: pure Across V4 lane - confirm the fee-0 LiFi integrator returns pure routes (sec 8 gate)"
            );
        }
        if (chainId == CrossChainConfig.CHAIN_ARBITRUM) {
            // The bridger hard-pins Base as destination; a post-cutover deploy here would ship the
            // new hub's own revenue back to Base.
            console.log("  WARNING: the Arbitrum lane is PRE-CUTOVER ONLY. Once the BWS migration makes");
            console.log("           Arbitrum the hub, do NOT deploy or repoint this lane - retire it.");
        }
        if (chainId == CrossChainConfig.CHAIN_FRAXTAL) {
            console.log("  NOTE: Fraxtal/Glacis charges a native FRAX fee - keeper attaches it as msg.value per call");
        }
        if (chainId == CrossChainConfig.CHAIN_KATANA) {
            // KAT is not a canonical bridge token: every route swaps it on Katana first. The keeper
            // requests a Symbiosis route delivering WETH so the swap is bundled into one composed tx
            // matching the allowlisted selector, with hasDestinationCall=false.
            console.log(
                "  NOTE: Katana keeper must request a Symbiosis route delivering WETH (allowBridges=[symbiosis],"
            );
            console.log("        toToken=WETH) - composed KAT->WETH swap bundled in-tx, hasDestinationCall=false");
        }
        console.log("  -> repoint FeeCollector.treasury here; keep governanceVault == address(0)");
        console.log("     (carve-out: Arbitrum sets its vault to the BWS GovernanceVoter at the migration cutover)");
    }

    function _defaultRaiseToken(
        uint256 chainId
    ) internal pure returns (address) {
        if (chainId == CrossChainConfig.CHAIN_ETHEREUM) return CrossChainConfig.ETHEREUM_WETH;
        if (chainId == CrossChainConfig.CHAIN_INK) return CrossChainConfig.INK_WETH;
        if (chainId == CrossChainConfig.CHAIN_ARBITRUM) return CrossChainConfig.ARBITRUM_WETH;
        if (chainId == CrossChainConfig.CHAIN_FRAXTAL) return CrossChainConfig.FRAXTAL_FRXUSD;
        return address(0); // Katana KAT (and any other lane) must be supplied via RAISE_TOKEN
    }
}

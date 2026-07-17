// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {RevenueBridger} from "src/crosschain/RevenueBridger.sol";
import {EthereumRevenueSwapper} from "src/crosschain/EthereumRevenueSwapper.sol";
import {CrossChainConfig} from "script/CrossChainConfig.sol";

/// @title DeployRevenueBridging
/// @notice Deploys Boardwalk's cross-chain revenue bridging: the `EthereumRevenueSwapper` on
///         Ethereum (the hub) and a generic `RevenueBridger` on every non-Ethereum LiFi lane
///         (Base, Arbitrum, Robinhood).
/// @dev Deploy order:
///      1. Ethereum: run this script, which deploys `EthereumRevenueSwapper`. Record its address;
///         every lane pins it as `ETHEREUM_DESTINATION`.
///      2. Each non-Ethereum chain: rerun with ETHEREUM_DESTINATION set to the swapper from
///         step 1. Every lane is a pure Across V4 WETH lane (msg.value == 0 per bridge call).
///      3. Byte-verify every external address against on-chain code before broadcasting, and
///         recompute the facet selector from LiFi source at this commit. Robinhood gotcha: gas
///         estimation there under-estimates — pad deploy gas (LiFi's own deploys needed large
///         multipliers).
///      4. transferOwnership (2-step) of all deployed contracts to the multisig.
///      5. Use a separate key on a separate host for each role: the source
///         `BoardwalkFeeCollector.keeper` (accrual), each bridger's keeper (bridge), and the
///         Ethereum swapper keeper.
///      6. Repoint revenue: per source chain, `BoardwalkFeeCollector.signal/executeSetTreasury`
///         (7-day timelock) to the deployed bridger so `forwardRevenue` routes revenue in.
///      7. Keep `governanceVault == address(0)` on all source chains (Base, Arbitrum, Robinhood);
///         a set vault diverts 90% of `forwardRevenue` past the bridger. Never call
///         `executeSetGovernanceVault` there; alert on `GovernanceVaultUpdated`. Ethereum is the
///         governance home — its FeeCollector's vault is set to the BWLK GovernanceVoter (the one
///         legitimate `GovernanceVaultUpdated`), and Ethereum has NO lane: this script deploys
///         only the swapper there.
///      8. Accrual gating: don't call `forwardRevenue` until monitoring confirms the previous
///         bridge landed on Ethereum. The 10/90 split lands when the Ethereum FeeCollector runs
///         its regular cycle.
///
///      Required env: KEEPER. Ethereum also: FEE_COLLECTOR. Non-Ethereum also:
///      ETHEREUM_DESTINATION. Optional: OWNER (default deployer), MAX_FEE_BPS, RAISE_TOKEN
///      (defaults to the chain's canonical WETH).
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

        if (chainId == CrossChainConfig.CHAIN_ETHEREUM) {
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
        address weth = CrossChainConfig.ETHEREUM_WETH;
        address feeCollector = vm.envAddress("FEE_COLLECTOR");

        require(allowanceHolder.code.length > 0, "AllowanceHolder: no code");
        require(weth.code.length > 0, "WETH: no code");
        require(feeCollector.code.length > 0, "FeeCollector: no code");

        EthereumRevenueSwapper swapper = new EthereumRevenueSwapper(owner, allowanceHolder, weth, feeCollector, keeper);
        console.log("EthereumRevenueSwapper:", address(swapper));
        console.log("  -> set this as ETHEREUM_DESTINATION on every non-Ethereum lane");
        console.log("  -> the swap leg is keeper-trusted (keeper supplies tokenIn + 0x calldata + minOut)");
    }

    function _deployLifiBridger(
        address owner,
        address keeper,
        uint256 chainId
    ) internal {
        address diamond = CrossChainConfig.lifiDiamond(chainId);
        require(diamond.code.length > 0, "diamond: no code");

        address ethereumDestination = vm.envAddress("ETHEREUM_DESTINATION");
        require(ethereumDestination != address(0), "ETHEREUM_DESTINATION required");
        address raiseToken = vm.envOr("RAISE_TOKEN", CrossChainConfig.laneRaiseToken(chainId));
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
            ethereumDestination,
            CrossChainConfig.ETHEREUM_WETH,
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
        console.log("  NOTE: pure Across V4 lane - confirm the fee-0 LiFi integrator returns pure routes (sec 8 gate)");
        console.log("  -> repoint FeeCollector.treasury here; keep governanceVault == address(0)");
        console.log("     (Ethereum is the hub: its FeeCollector's vault points at the BWLK GovernanceVoter)");
    }
}

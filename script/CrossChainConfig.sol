// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title CrossChainConfig
/// @notice Per-chain addresses and constants for Boardwalk's cross-chain revenue bridging (the LiFi
///         `RevenueBridger` on every non-Ethereum lane and the Ethereum `EthereumRevenueSwapper`).
/// @dev    Byte-verify every address against on-chain code at the target deploy commit. The per-chain
///         LiFi Diamond is not one canonical address: Robinhood differs, and the canonical address
///         has no code there. Owner, keepers, treasury, and `MAX_FEE_BPS` come from the deploy env,
///         not from here.
library CrossChainConfig {
    uint256 internal constant CHAIN_ETHEREUM = 1;
    uint256 internal constant CHAIN_BASE = 8453;
    uint256 internal constant CHAIN_ARBITRUM = 42161;
    uint256 internal constant CHAIN_ROBINHOOD = 4663;

    /// @notice LiFi facet selector (recompute from source at the target commit). Every lane is a
    ///         pure Across V4 WETH lane; no composed (source-swap) lane exists in this chain set.
    bytes4 internal constant ACROSS_V4_SELECTOR = 0xa1f1ce43; // startBridgeTokensViaAcrossV4

    /// @notice The Ethereum destination chain id every LiFi lane must pin.
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    /// @notice Canonical WETH on Ethereum; the pinned Across V4 output asset and the hub raise token.
    address internal constant ETHEREUM_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice Canonical WETH on Base, Arbitrum, and Robinhood (each lane's raise token).
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant ARBITRUM_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant ROBINHOOD_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    /// @notice The 0x AllowanceHolder on Ethereum (Cancun/transient-storage build); the swapper's only
    ///         legal swap target.
    address internal constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    /// @notice Default Across `outputAmount` floor (BPS). Size per lane at build.
    uint256 internal constant DEFAULT_MAX_FEE_BPS = 30;

    error UnsupportedChainId(uint256 chainId);

    /// @notice The per-chain LiFi Diamond (the only legal call target for `RevenueBridger`).
    ///         Ethereum is the hub — it has no lane and resolves no diamond.
    function lifiDiamond(
        uint256 chainId
    ) internal pure returns (address) {
        if (chainId == CHAIN_BASE || chainId == CHAIN_ARBITRUM) {
            return 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;
        }
        if (chainId == CHAIN_ROBINHOOD) return 0xB477751B76CF82d00a686A1232f5fCD772414Af3;
        revert UnsupportedChainId(chainId);
    }

    /// @notice The lane's single allowlisted facet selector (one shape per lane, matching
    ///         `hasSourceSwaps`).
    function lifiSelector(
        uint256 chainId
    ) internal pure returns (bytes4) {
        if (chainId == CHAIN_BASE || chainId == CHAIN_ARBITRUM || chainId == CHAIN_ROBINHOOD) {
            return ACROSS_V4_SELECTOR;
        }
        revert UnsupportedChainId(chainId);
    }

    /// @notice The lane's `HAS_SOURCE_SWAPS` immutable. All lanes are `false` (pure Across V4
    ///         via the fee-0 integrator); re-verify before locking it in.
    function hasSourceSwaps(
        uint256 chainId
    ) internal pure returns (bool) {
        if (chainId == CHAIN_BASE || chainId == CHAIN_ARBITRUM || chainId == CHAIN_ROBINHOOD) return false;
        revert UnsupportedChainId(chainId);
    }

    /// @notice The lane's raise token (canonical WETH on every source chain).
    function laneRaiseToken(
        uint256 chainId
    ) internal pure returns (address) {
        if (chainId == CHAIN_BASE) return BASE_WETH;
        if (chainId == CHAIN_ARBITRUM) return ARBITRUM_WETH;
        if (chainId == CHAIN_ROBINHOOD) return ROBINHOOD_WETH;
        revert UnsupportedChainId(chainId);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title CrossChainConfig
/// @notice Per-chain addresses and constants for Boardwalk's cross-chain revenue bridging (the LiFi
///         `RevenueBridger` on every non-Base lane and the Base `BaseRevenueSwapper`).
/// @dev    Byte-verify every address against on-chain code at the target deploy commit. The per-chain
///         LiFi Diamond is not one canonical address: Ink and Katana differ, and the canonical address
///         has no code there. Raise tokens, owner, keepers, treasury, and `MAX_FEE_BPS` come from the
///         deploy env, not from here.
library CrossChainConfig {
    uint256 internal constant CHAIN_ETHEREUM = 1;
    uint256 internal constant CHAIN_BASE = 8453;
    uint256 internal constant CHAIN_KATANA = 747474;
    uint256 internal constant CHAIN_FRAXTAL = 252;
    uint256 internal constant CHAIN_INK = 57073;
    uint256 internal constant CHAIN_ARBITRUM = 42161;

    /// @notice LiFi facet selectors (recompute from source at the target commit).
    bytes4 internal constant ACROSS_V4_SELECTOR = 0xa1f1ce43; // startBridgeTokensViaAcrossV4
    bytes4 internal constant SYMBIOSIS_SELECTOR = 0x6e067161; // swapAndStartBridgeTokensViaSymbiosis
    bytes4 internal constant GLACIS_SELECTOR = 0x9c4b6dd9; // swapAndStartBridgeTokensViaGlacis

    /// @notice The Base destination chain id every LiFi lane must pin.
    uint256 internal constant BASE_CHAIN_ID = 8453;
    /// @notice Canonical WETH on Base (OP-stack predeploy); the pinned Across V4 output asset.
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    /// @notice Canonical WETH on Ethereum, Ink, and Arbitrum (the WETH-lane raise token).
    address internal constant ETHEREUM_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant INK_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant ARBITRUM_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    /// @notice The 0x AllowanceHolder on Base (Cancun/transient-storage build); the swapper's only
    ///         legal swap target.
    address internal constant ZEROX_ALLOWANCE_HOLDER = 0x0000000000001fF3684f28c67538d4D072C22734;

    /// @notice frxUSD on Fraxtal (the Fraxtal raise token, bridged to Base via LiFi/Glacis) and the
    ///         Base-side frxUSD token (the asset the LiFi route delivers to the swapper, swapped to
    ///         WETH there). Byte-verify both at the deploy commit.
    address internal constant FRAXTAL_FRXUSD = 0xFc00000000000000000000000000000000000001;
    address internal constant BASE_FRXUSD = 0xe5020A6d073a794B6E7f05678707dE47986Fb0b6;

    /// @notice Default Across `outputAmount` floor (BPS). Size per ETH/Ink/Arbitrum at build.
    uint256 internal constant DEFAULT_MAX_FEE_BPS = 30;

    error UnsupportedChainId(uint256 chainId);

    /// @notice The per-chain LiFi Diamond (the only legal call target for `RevenueBridger`).
    function lifiDiamond(
        uint256 chainId
    ) internal pure returns (address) {
        if (chainId == CHAIN_ETHEREUM || chainId == CHAIN_BASE || chainId == CHAIN_FRAXTAL || chainId == CHAIN_ARBITRUM)
        {
            return 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;
        }
        if (chainId == CHAIN_INK) return 0x864b314D4C5a0399368609581d3E8933a63b9232;
        if (chainId == CHAIN_KATANA) return 0xC59fe32C9549e3E8B5dCcdAbC45BD287Bd5bA2bc;
        revert UnsupportedChainId(chainId);
    }

    /// @notice The lane's single allowlisted facet selector (one shape per lane, matching
    ///         `hasSourceSwaps`).
    function lifiSelector(
        uint256 chainId
    ) internal pure returns (bytes4) {
        if (chainId == CHAIN_ETHEREUM || chainId == CHAIN_INK || chainId == CHAIN_ARBITRUM) return ACROSS_V4_SELECTOR;
        if (chainId == CHAIN_KATANA) return SYMBIOSIS_SELECTOR;
        if (chainId == CHAIN_FRAXTAL) return GLACIS_SELECTOR;
        revert UnsupportedChainId(chainId);
    }

    /// @notice The lane's `HAS_SOURCE_SWAPS` immutable. ETH/Ink/Arbitrum are `false` (pure Across V4
    ///         via the fee-0 integrator); re-verify before locking it in.
    function hasSourceSwaps(
        uint256 chainId
    ) internal pure returns (bool) {
        if (chainId == CHAIN_ETHEREUM || chainId == CHAIN_INK || chainId == CHAIN_ARBITRUM) return false;
        if (chainId == CHAIN_KATANA || chainId == CHAIN_FRAXTAL) return true;
        revert UnsupportedChainId(chainId);
    }
}

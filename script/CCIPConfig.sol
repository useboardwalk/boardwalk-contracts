// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title CCIPConfig
/// @notice Canonical per-chain Chainlink CCIP routers and chain selectors for Boardwalk
///         deployments.
/// @dev    Verified against the CCIP Directory, the chain-selectors registry, and live
///         `Router.isChainSupported` calls (July 2026); every Base<->spoke lane is live in both
///         directions (Robinhood's only CCIP counterparties are Ethereum and Base). Spoke<->spoke
///         lanes are not assumed; the bridge is hub-and-spoke via Base.
library CCIPConfig {
    uint256 internal constant CHAIN_ETHEREUM = 1;
    uint256 internal constant CHAIN_BASE = 8453;
    uint256 internal constant CHAIN_ARBITRUM = 42161;
    uint256 internal constant CHAIN_ROBINHOOD = 4663;

    uint64 internal constant SELECTOR_ETHEREUM = 5009297550715157269;
    uint64 internal constant SELECTOR_BASE = 15971525489660198786;
    uint64 internal constant SELECTOR_ARBITRUM = 4949039107694359620;
    uint64 internal constant SELECTOR_ROBINHOOD = 6180753054346818345;

    error UnsupportedChainId(uint256 chainId);

    /// @notice Resolve the CCIP router and chain selector for `chainId`. Reverts if unsupported.
    /// @param chainId The chain to resolve CCIP config for.
    /// @return router The chain's CCIP Router.
    /// @return chainSelector The chain's CCIP selector.
    function resolve(
        uint256 chainId
    ) internal pure returns (address router, uint64 chainSelector) {
        if (chainId == CHAIN_ETHEREUM) return (0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D, SELECTOR_ETHEREUM);
        if (chainId == CHAIN_BASE) return (0x881e3A65B4d4a04dD529061dd0071cf975F58bCD, SELECTOR_BASE);
        if (chainId == CHAIN_ARBITRUM) return (0x141fa059441E0ca23ce184B6A78bafD2A517DdE8, SELECTOR_ARBITRUM);
        if (chainId == CHAIN_ROBINHOOD) return (0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9, SELECTOR_ROBINHOOD);
        revert UnsupportedChainId(chainId);
    }
}

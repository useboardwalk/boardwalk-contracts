// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title CCIPConfig
/// @notice Canonical per-chain Chainlink CCIP routers and chain selectors for Boardwalk
///         deployments.
/// @dev    Verified against the CCIP Directory and live `Router.isChainSupported` calls
///         (June 2026); every Base<->spoke lane is live in both directions. Spoke<->spoke lanes
///         are not assumed (Ink<->Fraxtal does not exist); the bridge is hub-and-spoke via Base.
library CCIPConfig {
    uint256 internal constant CHAIN_ETHEREUM = 1;
    uint256 internal constant CHAIN_BASE = 8453;
    uint256 internal constant CHAIN_KATANA = 747474;
    uint256 internal constant CHAIN_FRAXTAL = 252;
    uint256 internal constant CHAIN_INK = 57073;
    uint256 internal constant CHAIN_ARBITRUM = 42161;

    uint64 internal constant SELECTOR_ETHEREUM = 5009297550715157269;
    uint64 internal constant SELECTOR_BASE = 15971525489660198786;
    uint64 internal constant SELECTOR_KATANA = 2459028469735686113;
    uint64 internal constant SELECTOR_FRAXTAL = 1462016016387883143;
    uint64 internal constant SELECTOR_INK = 3461204551265785888;
    uint64 internal constant SELECTOR_ARBITRUM = 4949039107694359620;

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
        if (chainId == CHAIN_KATANA) return (0x7c19b79D2a054114Ab36ad758A36e92376e267DA, SELECTOR_KATANA);
        if (chainId == CHAIN_FRAXTAL) return (0x4bdF20477744Ec5F9DE738b5cC9ACd01763905ee, SELECTOR_FRAXTAL);
        if (chainId == CHAIN_INK) return (0xca7c90A52B44E301AC01Cb5EB99b2fD99339433A, SELECTOR_INK);
        if (chainId == CHAIN_ARBITRUM) return (0x141fa059441E0ca23ce184B6A78bafD2A517DdE8, SELECTOR_ARBITRUM);
        revert UnsupportedChainId(chainId);
    }
}

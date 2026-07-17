// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title DexConfig
/// @notice Canonical Uniswap V2 factory/router and wrapped-native (WETH) addresses per supported
///         chain. Boardwalk deploys directly against Uniswap V2 — there is no Boardwalk-owned DEX.
/// @dev    All addresses are the official Uniswap Labs deployments (developers.uniswap.org V2
///         deployments; Robinhood is a day-one official deployment). Verified on-chain July 2026:
///         non-empty code, `router.factory()` returns the factory, `router.WETH()` returns the
///         chain's canonical WETH. Byte-verify again at the target deploy commit. The V2 protocol
///         fee switch (`factory.feeTo()`) is ON on Ethereum/Base/Arbitrum (LPs 0.25%, protocol
///         0.05%) and OFF on Robinhood as of July 2026 (LPs earn the full 0.30% there); the total
///         0.30% pair fee is the same either way.
library DexConfig {
    uint256 internal constant CHAIN_ETHEREUM = 1;
    uint256 internal constant CHAIN_BASE = 8453;
    uint256 internal constant CHAIN_ARBITRUM = 42161;
    uint256 internal constant CHAIN_ROBINHOOD = 4663;

    error UnsupportedChainId(uint256 chainId);

    /// @notice Resolve the canonical Uniswap V2 factory, router, and WETH for `chainId`.
    /// @param chainId The chain to resolve DEX config for.
    /// @return factory The Uniswap V2 factory.
    /// @return router The UniswapV2Router02.
    /// @return weth The chain's canonical wrapped native token (the raise token).
    function resolve(
        uint256 chainId
    ) internal pure returns (address factory, address router, address weth) {
        if (chainId == CHAIN_ETHEREUM) {
            return (
                0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f,
                0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D,
                0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
            );
        }
        if (chainId == CHAIN_BASE) {
            return (
                0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6,
                0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24,
                0x4200000000000000000000000000000000000006
            );
        }
        if (chainId == CHAIN_ARBITRUM) {
            return (
                0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9,
                0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24,
                0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
            );
        }
        if (chainId == CHAIN_ROBINHOOD) {
            return (
                0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f,
                0x89e5DB8B5aA49aA85AC63f691524311AEB649eba,
                0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
            );
        }
        revert UnsupportedChainId(chainId);
    }
}

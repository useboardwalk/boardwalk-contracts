// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @notice Minimal consumer interface for the canonical Uniswap V2 pair; declares only the call
///         our contracts make (PresaleManager mints LP directly against the pair when seeding).
interface IUniswapV2Pair {
    function mint(
        address to
    ) external returns (uint256 liquidity);
}

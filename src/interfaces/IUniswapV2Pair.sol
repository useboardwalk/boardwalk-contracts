// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @notice Minimal consumer interface for the canonical Uniswap V2 pair; declares only the call
///         our contracts make (PresaleManager mints LP directly against the pair when seeding).
interface IUniswapV2Pair {
    /// @notice Mints LP tokens against the token balances transferred to the pair since the last
    ///         sync.
    /// @param to Recipient of the minted LP tokens.
    /// @return liquidity The amount of LP tokens minted.
    function mint(
        address to
    ) external returns (uint256 liquidity);
}

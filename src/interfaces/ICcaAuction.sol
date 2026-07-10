// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @notice The one Uniswap CCA call UnsoldBurner makes. The auction is pull-based: unsold tokens leave
///         only when its `tokensRecipient` calls this (gated to the recipient, one-shot, only after the
///         auction ends). Matches ContinuousClearingAuction.sol at Uniswap/continuous-clearing-auction.
interface ICcaAuction {
    function sweepUnsoldTokens() external;
}

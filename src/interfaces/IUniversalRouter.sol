// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @notice Minimal interface for Uniswap's Universal Router
/// @dev See https://docs.uniswap.org/contracts/universal-router/technical-reference
interface IUniversalRouter {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs
    ) external payable;
}

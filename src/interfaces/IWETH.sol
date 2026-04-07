// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @notice Minimal WETH interface for wrapping/unwrapping native ETH
interface IWETH {
    function deposit() external payable;
    function withdraw(
        uint256 amount
    ) external;
}

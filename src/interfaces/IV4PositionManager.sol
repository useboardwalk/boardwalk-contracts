// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IV4PositionManager {
    function nextTokenId() external view returns (uint256);
    function modifyLiquidities(
        bytes calldata unlockData,
        uint256 deadline
    ) external payable;
}

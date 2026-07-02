// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IV4PositionManager {
    /// @dev ABI-compatible mirror of the v4 `PoolKey` (Currency/IHooks are address-wrapped).
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    function nextTokenId() external view returns (uint256);
    function modifyLiquidities(
        bytes calldata unlockData,
        uint256 deadline
    ) external payable;

    /// @notice Returns the pool key and packed position info for a position NFT.
    function getPoolAndPositionInfo(
        uint256 tokenId
    ) external view returns (PoolKey memory poolKey, uint256 info);
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface ILPLocker {
    error NotAuthorized();
    error PositionNotLocked();
    error AlreadyLocked();
    error NoPositions();

    event LPLocked(uint256 indexed tokenId);
    event FeesClaimed(uint256 indexed tokenId);

    function GOVERNANCE_VOTER() external view returns (address);

    function lockPosition(
        uint256 tokenId
    ) external;

    function claimFees(
        uint256 tokenId
    ) external;

    function claimAllFees() external;

    function lockedPositions(
        uint256 tokenId
    ) external view returns (bool);

    function lockedTokenIds(
        uint256 index
    ) external view returns (uint256);

    function getLockedPositions() external view returns (uint256[] memory);
}

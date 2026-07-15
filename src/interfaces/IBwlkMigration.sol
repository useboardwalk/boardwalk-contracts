// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IBwlkMigration {
    error ZeroAddress();
    error AlreadyMigrated();
    error NothingToMigrate();
    error ClaimWindowClosed();
    error ClaimWindowOpen();
    error InvalidProof();
    error FinalizationInProgress();
    error RootNotSet();
    error RootAlreadySet();
    error DeadlineInPast();

    event MerkleRootSet(bytes32 oldRoot, bytes32 newRoot);
    event Migrated(address indexed account, address indexed destination, uint256 bwlkAmount, uint256 pointsCredited);
    event PointsCredited(address indexed destination, uint256 amount);
    event Swept(address indexed to, uint256 amount);

    function setMerkleRoot(
        bytes32 newRoot
    ) external;

    function migrate(
        address destination,
        uint256 snapshotBmx,
        uint256 snapshotPoints,
        bytes32[] calldata proof
    ) external;

    function creditPoints(
        address destination,
        uint256 amount
    ) external;

    function sweepUnclaimed(
        address to
    ) external;

    function DEAD() external view returns (address);

    function CREDIT_BPS() external view returns (uint256);

    function BMX() external view returns (address);

    function BWLK() external view returns (address);

    function STAKED_BWLK_TRACKER() external view returns (address);

    function BONUS_BWLK_TRACKER() external view returns (address);

    function FEE_BWLK_TRACKER() external view returns (address);

    function BN_BWLK() external view returns (address);

    function VOTER() external view returns (address);

    function CLAIM_DEADLINE() external view returns (uint256);

    function merkleRoot() external view returns (bytes32);

    function migrated(
        address account
    ) external view returns (bool);
}

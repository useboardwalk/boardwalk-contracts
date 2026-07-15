// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IRewardTracker} from "../interfaces/IRewardTracker.sol";
import {IMintable} from "../interfaces/IMintable.sol";
import {IGovernanceVoter} from "../interfaces/IGovernanceVoter.sol";

/// @title BwlkMigration
/// @notice BMX holders can swap their tokens 1:1 for staked BWLK on Arbitrum.
///         Migrating burns all your BMX and gives you BWLK staked across all reward trackers,
///         plus 16% of the migrated amount as voter points. Snapshot stakers carry over a
///         portion of past points; new users still get the 16% credit.
contract BwlkMigration is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant BPS = 10_000;
    /// @notice Voter-point credit rate (16%): applied to the migrated BMX + carried-over points.
    uint256 public constant CREDIT_BPS = 1_600;

    IERC20 public immutable BMX;
    IERC20 public immutable BWLK;
    IRewardTracker public immutable STAKED_BWLK_TRACKER;
    IRewardTracker public immutable BONUS_BWLK_TRACKER;
    IRewardTracker public immutable FEE_BWLK_TRACKER;
    IMintable public immutable BN_BWLK;
    address public immutable VOTER;
    /// @dev Migration is only possible at or before this timestamp; sweep only after.
    uint256 public immutable CLAIM_DEADLINE;

    bytes32 public merkleRoot;

    /// @dev One migration per address, ever.
    mapping(address account => bool) public migrated;

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

    /// @param owner_ Admin: sets the root, credits points, sweeps.
    /// @param bmx Legacy BMX token on this chain.
    /// @param bwlk BWLK token.
    /// @param stakedBwlkTracker sBWLK tracker (staked BWLK).
    /// @param bonusBwlkTracker sbBWLK tracker (staked + bonus BWLK).
    /// @param feeBwlkTracker sbfBWLK tracker (staked + bonus + fee BWLK).
    /// @param bnBwlk Voter points token.
    /// @param voter GovernanceVoter contract.
    /// @param claimDeadline Last timestamp at which migration is allowed.
    constructor(
        address owner_,
        address bmx,
        address bwlk,
        address stakedBwlkTracker,
        address bonusBwlkTracker,
        address feeBwlkTracker,
        address bnBwlk,
        address voter,
        uint256 claimDeadline
    ) Ownable(owner_) {
        if (
            bmx == address(0) || bwlk == address(0) || stakedBwlkTracker == address(0) || bonusBwlkTracker == address(0)
                || feeBwlkTracker == address(0) || bnBwlk == address(0) || voter == address(0)
        ) revert ZeroAddress();
        if (claimDeadline <= block.timestamp) revert DeadlineInPast();

        BMX = IERC20(bmx);
        BWLK = IERC20(bwlk);
        STAKED_BWLK_TRACKER = IRewardTracker(stakedBwlkTracker);
        BONUS_BWLK_TRACKER = IRewardTracker(bonusBwlkTracker);
        FEE_BWLK_TRACKER = IRewardTracker(feeBwlkTracker);
        BN_BWLK = IMintable(bnBwlk);
        VOTER = voter;
        CLAIM_DEADLINE = claimDeadline;
    }

    /// @notice Set the snapshot merkle root once, before go-live.
    function setMerkleRoot(
        bytes32 newRoot
    ) external onlyOwner {
        if (merkleRoot != bytes32(0)) revert RootAlreadySet();
        emit MerkleRootSet(bytes32(0), newRoot);
        merkleRoot = newRoot;
    }

    /// @notice Migrate the caller's entire BMX balance to a staked BWLK position for `destination`.
    /// @dev Pass 0 for `snapshotBmx` + `snapshotPoints` and an empty proof for non-stakers.
    /// @param destination Receives the staked BWLK + voter points.
    /// @param snapshotBmx Caller's snapshot staked BMX (the carry ratio denominator).
    /// @param snapshotPoints Caller's snapshot voter points to carry over.
    /// @param proof Merkle proof for the (caller, snapshotBmx, snapshotPoints) leaf.
    function migrate(
        address destination,
        uint256 snapshotBmx,
        uint256 snapshotPoints,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (destination == address(0)) revert ZeroAddress();
        if (merkleRoot == bytes32(0)) revert RootNotSet();
        if (block.timestamp > CLAIM_DEADLINE) revert ClaimWindowClosed();
        if (migrated[msg.sender]) revert AlreadyMigrated();
        if (IGovernanceVoter(VOTER).finalizationInProgress()) revert FinalizationInProgress();

        uint256 bmxIn = BMX.balanceOf(msg.sender);
        if (bmxIn == 0) revert NothingToMigrate();

        migrated[msg.sender] = true;

        uint256 points;
        if (snapshotBmx != 0 || snapshotPoints != 0 || proof.length != 0) {
            // Staker with a snapshot leaf: base credit on the migrated BMX + carried points.
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, snapshotBmx, snapshotPoints))));
            if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();
            points = _pointsFor(bmxIn, snapshotBmx, snapshotPoints);
        } else {
            // No snapshot leaf (non-staker): just the 16% base credit on the migrated BMX.
            points = bmxIn * CREDIT_BPS / BPS;
        }

        // Burn the caller's entire BMX balance.
        BMX.safeTransferFrom(msg.sender, DEAD, bmxIn);

        // Build the staked BWLK position for `destination`, then credit voter points.
        _stakeBwlk(destination, bmxIn);
        if (points != 0) _stakePoints(destination, points);

        emit Migrated(msg.sender, destination, bmxIn, points);
    }

    /// @notice Credit voter points to `destination`, valid before or after that address has migrated.
    function creditPoints(
        address destination,
        uint256 amount
    ) external onlyOwner {
        if (destination == address(0)) revert ZeroAddress();
        if (IGovernanceVoter(VOTER).finalizationInProgress()) revert FinalizationInProgress();
        _stakePoints(destination, amount);
        emit PointsCredited(destination, amount);
    }

    /// @notice After the claim window closes, sweep the unclaimed BWLK pool.
    function sweepUnclaimed(
        address to
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (block.timestamp <= CLAIM_DEADLINE) revert ClaimWindowOpen();
        uint256 bal = BWLK.balanceOf(address(this));
        BWLK.safeTransfer(to, bal);
        emit Swept(to, bal);
    }

    /// @dev Stake `amount` of BWLK for `account`. Tier-1 sBWLK funded by this contract, tiers 2-3 funded from the destination's freshly-minted tracker tokens (pulled via the handler bypass).
    function _stakeBwlk(
        address account,
        uint256 amount
    ) private {
        // Exact-approve exactly what sBWLK pulls; the tracker consumes it, leaving zero allowance.
        BWLK.forceApprove(address(STAKED_BWLK_TRACKER), amount);
        STAKED_BWLK_TRACKER.stakeForAccount(address(this), account, address(BWLK), amount);
        BONUS_BWLK_TRACKER.stakeForAccount(account, account, address(STAKED_BWLK_TRACKER), amount);
        FEE_BWLK_TRACKER.stakeForAccount(account, account, address(BONUS_BWLK_TRACKER), amount);
    }

    /// @dev Mint `amount` of voter points (bnBWLK) and stake it into the fee tracker for `account`.
    function _stakePoints(
        address account,
        uint256 amount
    ) private {
        BN_BWLK.mint(address(this), amount);
        IERC20(address(BN_BWLK)).forceApprove(address(FEE_BWLK_TRACKER), amount);
        FEE_BWLK_TRACKER.stakeForAccount(address(this), account, address(BN_BWLK), amount);
        // The real bnBWLK transferFrom skips allowance for handlers (the fee tracker is one), so the
        // approval above is never consumed - reset it rather than leave a standing allowance.
        IERC20(address(BN_BWLK)).forceApprove(address(FEE_BWLK_TRACKER), 0);
    }

    /// @dev Calculates points as base + carry:
    ///      - base: 16% of broughtBmx (CREDIT_BPS/BPS * broughtBmx)
    ///      - carry: (1 + CREDIT_BPS/BPS) * snapshotPoints * min(broughtBmx, snapshotBmx) / snapshotBmx
    ///        (prior points + 16% bonus, scaled by migrated fraction; zero if snapshotBmx == 0)
    function _pointsFor(
        uint256 broughtBmx,
        uint256 snapshotBmx,
        uint256 snapshotPoints
    ) private pure returns (uint256) {
        uint256 base = broughtBmx * CREDIT_BPS / BPS;
        if (snapshotBmx == 0) return base;
        uint256 brought = broughtBmx < snapshotBmx ? broughtBmx : snapshotBmx;
        uint256 carry = snapshotPoints * (BPS + CREDIT_BPS) * brought / (BPS * snapshotBmx);
        return base + carry;
    }
}

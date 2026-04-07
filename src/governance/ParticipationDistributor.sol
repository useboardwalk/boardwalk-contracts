// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGovernanceVoter} from "../interfaces/IGovernanceVoter.sol";

/// @title ParticipationDistributor - 7-day linear BMX streaming to eligible governance voters
/// @notice When Option 4 wins, GovernanceVoter swaps raise token to BMX and calls createStream().
///         Eligible voters (those who voted in the PRIOR epoch) can claim their proportional share
///         linearly over 7 days. Eligibility is locked at vote time (wallet address, not staking position).
contract ParticipationDistributor {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant STREAM_DURATION = 7 days;

    // ============ Immutables ============

    address public immutable BMX;
    address public immutable GOVERNANCE_VOTER;

    // ============ Types ============

    struct StreamInfo {
        uint256 totalBmx;
        uint256 totalWeight;
        uint256 startTime;
    }

    // ============ State ============

    mapping(uint256 => StreamInfo) public streams;
    mapping(uint256 => mapping(address => uint256)) public claimed;

    // ============ Errors ============

    error NotGovernanceVoter();
    error StreamAlreadyExists();
    error NothingToClaim();

    // ============ Events ============

    event StreamCreated(uint256 indexed epoch, uint256 totalBmx, uint256 totalWeight);
    event Claimed(uint256 indexed epoch, address indexed user, uint256 amount);

    // ============ Constructor ============

    constructor(
        address _bmx,
        address _governanceVoter
    ) {
        BMX = _bmx;
        GOVERNANCE_VOTER = _governanceVoter;
    }

    // ============ Stream Management ============

    /// @notice Create a participation stream for an epoch. Only callable by GovernanceVoter.
    /// @param epoch The epoch this stream rewards (voters from epoch-1 are eligible)
    /// @param bmxAmount Total BMX to distribute
    function createStream(
        uint256 epoch,
        uint256 bmxAmount
    ) external {
        if (msg.sender != GOVERNANCE_VOTER) revert NotGovernanceVoter();
        if (streams[epoch].totalBmx != 0) revert StreamAlreadyExists();

        IGovernanceVoter.EpochInfo memory priorEpoch = IGovernanceVoter(GOVERNANCE_VOTER).getEpochInfo(epoch - 1);

        IERC20(BMX).safeTransferFrom(msg.sender, address(this), bmxAmount);

        streams[epoch] =
            StreamInfo({totalBmx: bmxAmount, totalWeight: priorEpoch.totalVoteWeight, startTime: block.timestamp});

        emit StreamCreated(epoch, bmxAmount, priorEpoch.totalVoteWeight);
    }

    // ============ Claiming ============

    /// @notice Claim vested BMX from a participation stream
    /// @param epoch The epoch to claim from
    function claim(
        uint256 epoch
    ) external {
        uint256 amount = _processClaim(epoch);
        if (amount == 0) revert NothingToClaim();
        IERC20(BMX).safeTransfer(msg.sender, amount);
    }

    /// @notice Claim vested BMX from multiple epoch streams in a single transaction
    /// @param epochs Array of epochs to claim from
    function claimAll(
        uint256[] calldata epochs
    ) external {
        uint256 total;
        for (uint256 i; i < epochs.length; ++i) {
            total += _processClaim(epochs[i]);
        }
        if (total == 0) revert NothingToClaim();
        IERC20(BMX).safeTransfer(msg.sender, total);
    }

    // ============ Internal ============

    /// @dev Process a single epoch claim: check claimable, update state, emit event
    function _processClaim(
        uint256 epoch
    ) internal returns (uint256 amount) {
        (, amount) = claimable(epoch, msg.sender);
        if (amount > 0) {
            claimed[epoch][msg.sender] += amount;
            emit Claimed(epoch, msg.sender, amount);
        }
    }

    // ============ View Functions ============

    /// @notice Get a user's total BMX allocation and currently claimable amount for an epoch
    /// @param epoch The epoch to check
    /// @param user The user address
    /// @return totalAllocation The total BMX the user is entitled to over the full stream
    /// @return claimableAmount The amount currently available to claim
    function claimable(
        uint256 epoch,
        address user
    ) public view returns (uint256 totalAllocation, uint256 claimableAmount) {
        StreamInfo memory s = streams[epoch];
        if (s.totalBmx == 0 || s.totalWeight == 0) return (0, 0);

        IGovernanceVoter.UserVote memory uv = IGovernanceVoter(GOVERNANCE_VOTER).getUserVote(epoch - 1, user);
        if (uv.option == 0) return (0, 0);

        totalAllocation = s.totalBmx * uv.weight / s.totalWeight;
        if (totalAllocation == 0) return (0, 0);

        uint256 elapsed = block.timestamp - s.startTime;
        uint256 vested;
        if (elapsed >= STREAM_DURATION) {
            vested = totalAllocation;
        } else {
            vested = totalAllocation * elapsed / STREAM_DURATION;
        }

        uint256 alreadyClaimed = claimed[epoch][user];
        if (vested > alreadyClaimed) {
            claimableAmount = vested - alreadyClaimed;
        }
    }
}

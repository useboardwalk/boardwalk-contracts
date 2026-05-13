// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGovernanceVoter} from "../interfaces/IGovernanceVoter.sol";
import {IParticipationDistributor} from "../interfaces/IParticipationDistributor.sol";

/// @title ParticipationDistributor
/// @notice 7-day linear BMX stream per epoch when governance Option 4 wins. Eligibility is locked
///         at vote time: voters from epoch N-1 share epoch N's BMX in proportion to their vote weight.
contract ParticipationDistributor is IParticipationDistributor {
    using SafeERC20 for IERC20;

    uint256 public constant STREAM_DURATION = 7 days;

    address public immutable BMX;
    address public immutable GOVERNANCE_VOTER;

    mapping(uint256 => StreamInfo) public streams;
    mapping(uint256 => mapping(address => uint256)) public claimed;

    constructor(
        address _bmx,
        address _governanceVoter
    ) {
        BMX = _bmx;
        GOVERNANCE_VOTER = _governanceVoter;
    }

    /// @notice Called by GovernanceVoter to start a new epoch's stream. Reads `totalVoteWeight` from
    ///         the prior epoch (`epoch - 1`) — that's the eligibility set for this stream.
    function createStream(
        uint256 epoch,
        uint256 bmxAmount
    ) external override {
        if (msg.sender != GOVERNANCE_VOTER) revert NotGovernanceVoter();
        if (streams[epoch].totalBmx != 0) revert StreamAlreadyExists();

        IGovernanceVoter.EpochInfo memory priorEpoch = IGovernanceVoter(GOVERNANCE_VOTER).getEpochInfo(epoch - 1);

        IERC20(BMX).safeTransferFrom(msg.sender, address(this), bmxAmount);

        streams[epoch] =
            StreamInfo({totalBmx: bmxAmount, totalWeight: priorEpoch.totalVoteWeight, startTime: block.timestamp});

        emit StreamCreated(epoch, bmxAmount, priorEpoch.totalVoteWeight);
    }

    function claim(
        uint256 epoch
    ) external override {
        uint256 amount = _processClaim(epoch);
        if (amount == 0) revert NothingToClaim();
        IERC20(BMX).safeTransfer(msg.sender, amount);
    }

    /// @notice Reverts if nothing is claimable across the supplied epochs (skips zero-claimable ones).
    function claimAll(
        uint256[] calldata epochs
    ) external override {
        uint256 total;
        for (uint256 i; i < epochs.length; ++i) {
            total += _processClaim(epochs[i]);
        }
        if (total == 0) revert NothingToClaim();
        IERC20(BMX).safeTransfer(msg.sender, total);
    }

    function _processClaim(
        uint256 epoch
    ) internal returns (uint256 amount) {
        (, amount) = claimable(epoch, msg.sender);
        if (amount > 0) {
            claimed[epoch][msg.sender] += amount;
            emit Claimed(epoch, msg.sender, amount);
        }
    }

    /// @notice Returns `(totalAllocation, claimableNow)` for `user` in `epoch`. Returns zero when the
    ///         user did not vote in epoch-1 or has no allocation.
    function claimable(
        uint256 epoch,
        address user
    ) public view override returns (uint256 totalAllocation, uint256 claimableAmount) {
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

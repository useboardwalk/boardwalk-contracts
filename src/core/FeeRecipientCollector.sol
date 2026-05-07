// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IBoardwalkToken} from "../interfaces/IBoardwalkToken.sol";
import {IFeeDistributor} from "../interfaces/IFeeDistributor.sol";
import {ILaunchFactory} from "../interfaces/ILaunchFactory.sol";

/// @title FeeRecipientCollector
/// @notice Partner-controlled per-role aggregator (integrator OR ancillary) for fees pushed by
///         every launch's FeeDistributor.
contract FeeRecipientCollector is Ownable2Step {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _trackedTokens;

    error UnknownSender();
    error NothingToClaim();
    error NotMyRole();

    event TokenRegistered(address indexed token, address indexed feeDistributor);
    event FeesClaimed(address indexed token, uint256 amount, address indexed to);
    event ClaimFailed(address indexed token);
    event TokenRemoved(address indexed token);

    constructor(
        address _owner
    ) Ownable(_owner) {}

    /// @dev Tokens already arrived via the preceding transfer; this call
    ///      just adds the token to the tracked set so `batchClaim` can find it.
    function notifyFees(
        address token,
        uint256 /*amount*/ // unused in this version
    ) external {
        if (IBoardwalkToken(token).feeDistributor() != msg.sender) revert UnknownSender();
        _trackedTokens.add(token);
        emit TokenRegistered(token, msg.sender);
    }

    /// @notice Owner drains the LAST `limit` tracked tokens. `limit == 0` claims everything.
    /// @dev    A token whose balance or transfer reverts is dropped from the set. Owner can
    ///         recover via `claimToken`.
    function batchClaim(
        uint256 limit
    ) external onlyOwner {
        uint256 len = _trackedTokens.length();
        if (len == 0) revert NothingToClaim();
        if (limit == 0 || limit > len) limit = len;

        uint256 snapshotIdx = len;
        for (uint256 i = 0; i < limit;) {
            unchecked {
                --snapshotIdx;
            }
            address token = _trackedTokens.at(snapshotIdx);
            _trackedTokens.remove(token);
            try this._safeClaimTo(token, msg.sender) returns (uint256 amount) {
                if (amount > 0) emit FeesClaimed(token, amount, msg.sender);
            } catch {
                emit ClaimFailed(token);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _safeClaimTo(
        address token,
        address to
    ) external returns (uint256 amount) {
        if (msg.sender != address(this)) revert UnknownSender();
        amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Claim a specific token regardless of being tracked.
    function claimToken(
        address token
    ) external onlyOwner {
        uint256 amount = IERC20(token).balanceOf(address(this));
        _trackedTokens.remove(token);
        if (amount > 0) {
            IERC20(token).safeTransfer(msg.sender, amount);
            emit FeesClaimed(token, amount, msg.sender);
        }
    }

    /// @notice Drop a junk token from the tracked set without claiming.
    function removeTrackedToken(
        address token
    ) external onlyOwner {
        _trackedTokens.remove(token);
        emit TokenRemoved(token);
    }

    /// @notice Batched signal of a role change across FeeDistributor clones.
    function signalChangeOnDistributors(
        address[] calldata distributors,
        address newAddress
    ) external onlyOwner {
        for (uint256 i = 0; i < distributors.length;) {
            if (IFeeDistributor(distributors[i]).integrator() == address(this)) {
                IFeeDistributor(distributors[i]).signalChangeIntegratorAddress(newAddress);
            } else if (IFeeDistributor(distributors[i]).ancillary() == address(this)) {
                IFeeDistributor(distributors[i]).signalChangeAncillaryAddress(newAddress);
            } else {
                revert NotMyRole();
            }
            unchecked {
                ++i;
            }
        }
    }

    function executeChangeOnDistributors(
        address[] calldata distributors,
        address newAddress
    ) external {
        for (uint256 i = 0; i < distributors.length;) {
            if (IFeeDistributor(distributors[i]).integrator() == address(this)) {
                IFeeDistributor(distributors[i]).executeChangeIntegratorAddress(newAddress);
            } else if (IFeeDistributor(distributors[i]).ancillary() == address(this)) {
                IFeeDistributor(distributors[i]).executeChangeAncillaryAddress(newAddress);
            } else {
                revert NotMyRole();
            }
            unchecked {
                ++i;
            }
        }
    }

    function cancelChangeOnDistributors(
        address[] calldata distributors
    ) external onlyOwner {
        for (uint256 i = 0; i < distributors.length;) {
            if (IFeeDistributor(distributors[i]).integrator() == address(this)) {
                IFeeDistributor(distributors[i]).cancelChangeIntegratorAddress();
            } else if (IFeeDistributor(distributors[i]).ancillary() == address(this)) {
                IFeeDistributor(distributors[i]).cancelChangeAncillaryAddress();
            } else {
                revert NotMyRole();
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Affects future launches only.
    function signalChangeOnFactory(
        address factory,
        address newAddress
    ) external onlyOwner {
        if (ILaunchFactory(factory).integrator() == address(this)) {
            ILaunchFactory(factory).signalChangeIntegratorAddress(newAddress);
        } else if (ILaunchFactory(factory).ancillary() == address(this)) {
            ILaunchFactory(factory).signalChangeAncillaryAddress(newAddress);
        } else {
            revert NotMyRole();
        }
    }

    function cancelChangeOnFactory(
        address factory
    ) external onlyOwner {
        if (ILaunchFactory(factory).integrator() == address(this)) {
            ILaunchFactory(factory).cancelChangeIntegratorAddress();
        } else if (ILaunchFactory(factory).ancillary() == address(this)) {
            ILaunchFactory(factory).cancelChangeAncillaryAddress();
        } else {
            revert NotMyRole();
        }
    }

    function trackedTokenCount() external view returns (uint256) {
        return _trackedTokens.length();
    }

    function trackedTokenAt(
        uint256 i
    ) external view returns (address) {
        return _trackedTokens.at(i);
    }

    function isTracked(
        address token
    ) external view returns (bool) {
        return _trackedTokens.contains(token);
    }
}

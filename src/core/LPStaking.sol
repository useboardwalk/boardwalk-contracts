// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title LPStaking
/// @notice Per-launch clone. Combines continuous 3-year vesting with weekly fee epochs and multiplier
///         points. Zero admin functions after `initialize`.
contract LPStaking is ReentrancyGuardTransient, Initializable {
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e30;
    uint256 public constant VESTING_DURATION = 3 * 365 days;
    uint256 public constant VESTING_DELAY = 24 hours;
    uint256 public constant EPOCH_DURATION = 7 days;
    address public constant DEAD_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    IERC20 public lpToken;
    IERC20 public rewardToken;
    address public feeDistributor;
    address public initAuthorizer;

    /// @dev 20% of (totalSupply - 2 * presaleTokens), set by PresaleManager.seedLiquidity().
    uint256 public vestingAllocation;
    uint256 public vestingStart;
    uint256 public vestingEnd;
    uint256 public baseVestingRate;

    uint256 public accRewardPerWeight;
    uint256 public totalWeight;
    uint256 public totalLpStaked;
    uint256 public lastRewardUpdate;

    uint256 public currentEpochStart;
    uint256 public currentEpochFees;
    /// @notice Fees accumulated during the current epoch N for streaming in the next epoch N+1.
    uint256 public pendingEpochFees;
    uint256 public feeRewardRate;

    struct UserInfo {
        uint256 lpStaked;
        uint256 multiplierPoints;
        uint256 lastMpUpdate;
        uint256 rewardDebt;
    }

    mapping(address => UserInfo) public userInfo;

    error CannotStakeZero();
    error InsufficientStake(uint256 available, uint256 requested);
    error OnlyFeeDistributor();
    error ZeroAddress();
    error NotInitializer();
    error InitializerAlreadySet();

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 mpBurned);
    event Claimed(address indexed user, uint256 amount);
    event VestingDistributed(uint256 amount);
    event FeesReceived(uint256 amount);
    /// @dev Emitted when fees arrive while there are zero stakers; the amount is burned
    event FeesLost(uint256 amount);
    event EpochAdvanced(uint256 epochStart, uint256 epochFees, uint256 feeRate);

    constructor() {
        _disableInitializers();
    }

    /// @notice Two-step initializer lock. Called once by the factory before `initialize`.
    function setInitializer(
        address _initAuthorizer
    ) external {
        if (initAuthorizer != address(0)) revert InitializerAlreadySet();
        if (_initAuthorizer == address(0)) revert ZeroAddress();
        initAuthorizer = _initAuthorizer;
    }

    function initialize(
        address _lpToken,
        address _rewardToken,
        address _feeDistributor,
        uint256 _seedTime,
        uint256 _vestingAllocation
    ) external initializer {
        if (msg.sender != initAuthorizer) revert NotInitializer();

        if (_lpToken == address(0)) revert ZeroAddress();
        if (_rewardToken == address(0)) revert ZeroAddress();
        if (_feeDistributor == address(0)) revert ZeroAddress();

        lpToken = IERC20(_lpToken);
        rewardToken = IERC20(_rewardToken);
        feeDistributor = _feeDistributor;

        vestingAllocation = _vestingAllocation;
        vestingStart = _seedTime + VESTING_DELAY;
        vestingEnd = vestingStart + VESTING_DURATION;
        baseVestingRate = _vestingAllocation / VESTING_DURATION;
        lastRewardUpdate = vestingStart;

        currentEpochStart = _seedTime;
    }

    /// @notice Stake LP. Auto-claims pending rewards.
    function stake(
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert CannotStakeZero();

        (UserInfo storage user, uint256 _accRPW,) = _settleAndUpdate(msg.sender);
        uint256 _lpStaked = user.lpStaked;

        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 _mp = user.multiplierPoints;
        uint256 oldWeight = _lpStaked + _mp;
        user.lpStaked = _lpStaked + amount;
        uint256 newWeight = _lpStaked + amount + _mp;

        totalWeight = totalWeight - oldWeight + newWeight;
        totalLpStaked += amount;
        user.rewardDebt = newWeight * _accRPW / PRECISION;

        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraw LP. Burns MP proportionally to the withdrawn share. Auto-claims.
    function withdraw(
        uint256 amount
    ) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        uint256 _lpStaked = user.lpStaked;
        if (_lpStaked < amount || amount == 0) {
            revert InsufficientStake(_lpStaked, amount);
        }

        (, uint256 _accRPW,) = _settleAndUpdate(msg.sender);

        uint256 _mp = user.multiplierPoints;
        uint256 mpToBurn = _mp * amount / _lpStaked;

        uint256 oldWeight = _lpStaked + _mp;
        user.lpStaked = _lpStaked - amount;
        user.multiplierPoints = _mp - mpToBurn;
        uint256 newWeight = _lpStaked - amount + _mp - mpToBurn;

        totalWeight = totalWeight - oldWeight + newWeight;
        totalLpStaked -= amount;
        user.rewardDebt = newWeight * _accRPW / PRECISION;

        lpToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, mpToBurn);
    }

    /// @notice Claim pending rewards without staking or withdrawing.
    function claim() external nonReentrant returns (uint256 pendingAmount) {
        UserInfo storage user;
        uint256 _accRPW;
        (user, _accRPW, pendingAmount) = _settleAndUpdate(msg.sender);
        user.rewardDebt = (user.lpStaked + user.multiplierPoints) * _accRPW / PRECISION;
    }

    /// @notice Called by FeeDistributor on every taxed transfer. Triggers epoch advance and accrues
    ///         the new amount into `pendingEpochFees`, which is streamed during the next epoch.
    function notifyFees(
        uint256 amount
    ) external {
        if (msg.sender != feeDistributor) revert OnlyFeeDistributor();

        _updateAllRewards();

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        // If no stakers, burn the fees
        if (totalWeight == 0) {
            rewardToken.safeTransfer(DEAD_ADDRESS, amount);
            emit FeesLost(amount);
            return;
        }

        pendingEpochFees += amount;

        emit FeesReceived(amount);
    }

    /// @dev Shared prefix for stake/withdraw/claim. Settles pending with the OLD weight before
    ///      updating MP, so the MP delta cannot inflate already-earned rewards.
    function _settleAndUpdate(
        address account
    ) internal returns (UserInfo storage user, uint256 _accRPW, uint256 pending) {
        _updateAllRewards();
        _accRPW = accRewardPerWeight;
        user = userInfo[account];
        if (user.lpStaked > 0) {
            pending = _pendingReward(user, _accRPW);
            if (pending > 0) {
                rewardToken.safeTransfer(account, pending);
                emit Claimed(account, pending);
            }
            user.rewardDebt = (user.lpStaked + user.multiplierPoints) * _accRPW / PRECISION;
        }
        _updateUserMp(user);
    }

    function _updateAllRewards() internal {
        _advanceEpochIfNeeded();
        _distributeRewards();
    }

    /// @dev Anchored to block.timestamp at trigger time, not the boundary, so every epoch gets a
    ///      full 7-day window even when the keeper is late.
    function _advanceEpochIfNeeded() internal {
        if (block.timestamp < currentEpochStart + EPOCH_DURATION) return;

        _distributeRewards();

        currentEpochStart = block.timestamp;
        currentEpochFees = pendingEpochFees;
        pendingEpochFees = 0;
        feeRewardRate = currentEpochFees / EPOCH_DURATION;

        emit EpochAdvanced(currentEpochStart, currentEpochFees, feeRewardRate);
    }

    /// @dev Both vesting and fee rewards are permanently LOST during zero-staker intervals.
    function _distributeRewards() internal {
        uint256 currentTime = block.timestamp;
        uint256 lastUpdate = lastRewardUpdate;

        if (currentTime <= lastUpdate) return;

        if (totalWeight == 0) {
            lastRewardUpdate = currentTime;
            return;
        }

        uint256 vestingReward = _calculateVestingReward(lastUpdate, currentTime);
        uint256 feeReward = _calculateFeeReward(lastUpdate, currentTime);
        uint256 totalReward = vestingReward + feeReward;
        if (totalReward > 0) {
            accRewardPerWeight += totalReward * PRECISION / totalWeight;
        }

        lastRewardUpdate = currentTime;

        if (vestingReward > 0) emit VestingDistributed(vestingReward);
    }

    function _calculateVestingReward(
        uint256 fromTime,
        uint256 toTime
    ) internal view returns (uint256) {
        if (baseVestingRate == 0) return 0;

        uint256 from = fromTime > vestingStart ? fromTime : vestingStart;
        uint256 to = toTime > vestingEnd ? vestingEnd : toTime;

        if (to <= from) return 0;

        return (to - from) * baseVestingRate;
    }

    function _calculateFeeReward(
        uint256 fromTime,
        uint256 toTime
    ) internal view returns (uint256) {
        if (feeRewardRate == 0) return 0;

        uint256 epochEnd = currentEpochStart + EPOCH_DURATION;

        uint256 from = fromTime > currentEpochStart ? fromTime : currentEpochStart;
        uint256 to = toTime > epochEnd ? epochEnd : toTime;

        if (to <= from) return 0;

        return (to - from) * feeRewardRate;
    }

    /// @dev MP accrual: 1 MP per LP per year (lazily crystallised on user interactions).
    function _updateUserMp(
        UserInfo storage user
    ) internal {
        if (user.lpStaked > 0 && user.lastMpUpdate > 0) {
            uint256 elapsed = block.timestamp - user.lastMpUpdate;
            uint256 newMp = user.lpStaked * elapsed / 365 days;
            if (newMp > 0) {
                totalWeight += newMp;
                user.multiplierPoints += newMp;
            }
        }
        user.lastMpUpdate = block.timestamp;
    }

    function _pendingRewardDelta(
        uint256 fromTime,
        uint256 toTime
    ) internal view returns (uint256) {
        return _calculateVestingReward(fromTime, toTime) + _calculateFeeReward(fromTime, toTime);
    }

    function _pendingReward(
        UserInfo memory user,
        uint256 _accRewardPerWeight
    ) internal pure returns (uint256) {
        uint256 weight = user.lpStaked + user.multiplierPoints;
        if (weight == 0) return 0;
        uint256 accumulated = weight * _accRewardPerWeight / PRECISION;
        return accumulated > user.rewardDebt ? accumulated - user.rewardDebt : 0;
    }

    function pendingRewards(
        address account
    ) external view returns (uint256) {
        return _simulatePendingRewards(account);
    }

    function _simulatePendingRewards(
        address account
    ) internal view returns (uint256) {
        UserInfo memory user = userInfo[account];

        uint256 simAccReward = accRewardPerWeight;
        if (totalWeight > 0) {
            uint256 delta = _pendingRewardDelta(lastRewardUpdate, block.timestamp);
            if (delta > 0) {
                simAccReward += delta * PRECISION / totalWeight;
            }
        }

        uint256 weight = user.lpStaked + user.multiplierPoints;
        if (weight == 0) return 0;
        uint256 accumulated = weight * simAccReward / PRECISION;
        return accumulated > user.rewardDebt ? accumulated - user.rewardDebt : 0;
    }

    function getPoolStats()
        external
        view
        returns (
            uint256 _totalLpStaked,
            uint256 _totalWeight,
            uint256 _vestingPerSecond,
            uint256 _vestingRemaining,
            uint256 _currentEpochFees,
            uint256 _feeRewardRate,
            uint256 _pendingEpochFees,
            uint256 _epochTimeRemaining
        )
    {
        _totalLpStaked = totalLpStaked;
        _totalWeight = totalWeight;
        _vestingPerSecond = block.timestamp < vestingEnd ? baseVestingRate : 0;

        uint256 vestingElapsed = block.timestamp > vestingStart
            ? (block.timestamp > vestingEnd ? vestingEnd : block.timestamp) - vestingStart
            : 0;
        uint256 vested = vestingElapsed * baseVestingRate;
        _vestingRemaining = vestingAllocation > vested ? vestingAllocation - vested : 0;

        _currentEpochFees = currentEpochFees;
        _feeRewardRate = feeRewardRate;
        _pendingEpochFees = pendingEpochFees;

        uint256 epochEnd = currentEpochStart + EPOCH_DURATION;
        _epochTimeRemaining = block.timestamp < epochEnd ? epochEnd - block.timestamp : 0;
    }

    function getUserInfo(
        address account
    )
        external
        view
        returns (uint256 stakedLp, uint256 currentMp, uint256 effectiveWeight, uint256 pending, uint256 poolShareBps)
    {
        UserInfo memory user = userInfo[account];
        stakedLp = user.lpStaked;
        currentMp = user.multiplierPoints;

        if (user.lpStaked > 0 && user.lastMpUpdate > 0) {
            uint256 elapsed = block.timestamp - user.lastMpUpdate;
            currentMp += user.lpStaked * elapsed / 365 days;
        }

        effectiveWeight = stakedLp + currentMp;
        pending = _simulatePendingRewards(account);
        // Use simulated totalWeight so the share never exceeds 10000 BPS for the calling user.
        uint256 simTotalWeight = totalWeight + (currentMp - user.multiplierPoints);
        poolShareBps = simTotalWeight > 0 ? effectiveWeight * 10000 / simTotalWeight : 0;
    }
}

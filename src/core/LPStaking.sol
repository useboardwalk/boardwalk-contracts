// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title LPStaking - Immutable LP staking with multiplier points and weekly fee epochs
/// @notice Per-launch clone. Combines continuous vesting distribution with weekly fee epochs.
contract LPStaking is ReentrancyGuardTransient, Initializable {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant PRECISION = 1e30;
    uint256 public constant VESTING_DURATION = 3 * 365 days;
    uint256 public constant VESTING_DELAY = 24 hours;
    uint256 public constant EPOCH_DURATION = 7 days;

    // ============ Initialized State ============

    IERC20 public lpToken;
    IERC20 public rewardToken;
    address public feeDistributor;
    address public initAuthorizer;

    /// @dev Set by PresaleManager during seedLiquidity(). Represents 20% of (totalSupply - 2*presaleTokens).
    uint256 public vestingAllocation;
    uint256 public vestingStart; // seedTime + 24h
    uint256 public vestingEnd; // vestingStart + 3 years
    uint256 public baseVestingRate; // vestingAllocation / VESTING_DURATION

    // ============ Global Reward State ============

    uint256 public accRewardPerWeight; // cumulative reward per unit of weight
    uint256 public totalWeight; // sum of LP + MP
    uint256 public totalLpStaked;
    uint256 public lastRewardUpdate;

    // ============ Weekly Fee Epoch State ============

    uint256 public currentEpochStart;
    uint256 public currentEpochFees;
    uint256 public pendingEpochFees; // fees received for the NEXT epoch
    uint256 public feeRewardRate; // tokens per second

    // ============ User State ============

    struct UserInfo {
        uint256 lpStaked;
        uint256 multiplierPoints;
        uint256 lastMpUpdate;
        uint256 rewardDebt;
    }

    mapping(address => UserInfo) public userInfo;

    // ============ Errors ============

    error CannotStakeZero();
    error InsufficientStake(uint256 available, uint256 requested);
    error OnlyFeeDistributor();
    error ZeroAddress();
    error NotInitializer();
    error InitializerAlreadySet();

    // ============ Events ============

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 mpBurned);
    event Claimed(address indexed user, uint256 amount);
    event VestingDistributed(uint256 amount);
    event FeesReceived(uint256 amount);
    event EpochAdvanced(uint256 epochStart, uint256 epochFees, uint256 feeRate);

    // ============ Constructor ============

    /// @dev Disable initialization on the implementation template
    constructor() {
        _disableInitializers();
    }

    // ============ Initialization ============

    /// @notice Set the authorized initializer (called once by factory immediately after clone deployment)
    /// @param _initAuthorizer Address authorized to call initialize()
    function setInitializer(
        address _initAuthorizer
    ) external {
        if (initAuthorizer != address(0)) revert InitializerAlreadySet();
        if (_initAuthorizer == address(0)) revert ZeroAddress();
        initAuthorizer = _initAuthorizer;
    }

    /// @notice Initialize the LPStaking clone
    /// @param _lpToken The LP token address
    /// @param _rewardToken The reward token address
    /// @param _feeDistributor The FeeDistributor clone address
    /// @param _seedTime Timestamp when liquidity was seeded
    /// @param _vestingAllocation Total LP incentive tokens allocated for vesting
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

        // First fee epoch starts at seed time
        currentEpochStart = _seedTime;
    }

    // ============ Core Functions ============

    /// @notice Stake LP tokens to earn vesting rewards and fee rewards
    /// @param amount Amount of LP tokens to stake
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

    /// @notice Withdraw LP tokens. Burns a proportional amount of multiplier points.
    /// @param amount Amount of LP tokens to withdraw
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

    /// @notice Claim accumulated rewards (vesting + fees)
    /// @return pendingAmount Amount of reward tokens claimed
    function claim() external nonReentrant returns (uint256 pendingAmount) {
        UserInfo storage user;
        uint256 _accRPW;
        (user, _accRPW, pendingAmount) = _settleAndUpdate(msg.sender);
        user.rewardDebt = (user.lpStaked + user.multiplierPoints) * _accRPW / PRECISION;
    }

    /// @notice Called by FeeDistributor to deposit fees for next epoch.
    /// @dev Triggers epoch advancement if needed.
    /// @param amount Amount of fee tokens to deposit
    function notifyFees(
        uint256 amount
    ) external {
        if (msg.sender != feeDistributor) revert OnlyFeeDistributor();

        // Advance epoch if needed (distributes previous epoch's fees)
        _updateAllRewards();

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        // Accumulate for next epoch (not distributed yet)
        pendingEpochFees += amount;

        emit FeesReceived(amount);
    }

    // ============ Internal: Settlement ============

    /// @dev Shared settlement sequence for stake/withdraw/claim.
    ///      Updates rewards, settles pending (with transfer + emit), then updates MP.
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

    // ============ Internal: Reward Updates ============

    /// @dev Updates both vesting rewards and fee epoch rewards
    function _updateAllRewards() internal {
        _advanceEpochIfNeeded();
        _distributeRewards();
    }

    /// @dev Advance to next epoch if current epoch has ended.
    ///      Anchors to block.timestamp so every epoch gets a full 7-day window.
    function _advanceEpochIfNeeded() internal {
        if (block.timestamp < currentEpochStart + EPOCH_DURATION) return;

        // Distribute any remaining rewards from current epoch before advancing
        _distributeRewards();

        // Start new epoch anchored to NOW (full 7-day window regardless of trigger timing)
        currentEpochStart = block.timestamp;
        currentEpochFees = pendingEpochFees;
        pendingEpochFees = 0;
        feeRewardRate = currentEpochFees / EPOCH_DURATION;

        emit EpochAdvanced(currentEpochStart, currentEpochFees, feeRewardRate);
    }

    /// @dev Distribute vesting + fee rewards to accumulator.
    ///      Both vesting AND fees are LOST during zero-staker periods.
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

    /// @dev Calculate vesting rewards between two timestamps, clamped to vesting bounds
    function _calculateVestingReward(
        uint256 fromTime,
        uint256 toTime
    ) internal view returns (uint256) {
        if (baseVestingRate == 0) return 0;

        // Clamp to vesting bounds
        uint256 from = fromTime > vestingStart ? fromTime : vestingStart;
        uint256 to = toTime > vestingEnd ? vestingEnd : toTime;

        if (to <= from) return 0;

        return (to - from) * baseVestingRate;
    }

    /// @dev Calculate fee rewards between two timestamps, clamped to current epoch bounds
    function _calculateFeeReward(
        uint256 fromTime,
        uint256 toTime
    ) internal view returns (uint256) {
        if (feeRewardRate == 0) return 0;

        uint256 epochEnd = currentEpochStart + EPOCH_DURATION;

        // Clamp to epoch bounds
        uint256 from = fromTime > currentEpochStart ? fromTime : currentEpochStart;
        uint256 to = toTime > epochEnd ? epochEnd : toTime;

        if (to <= from) return 0;

        return (to - from) * feeRewardRate;
    }

    /// @dev Update multiplier points for a user based on elapsed time.
    ///      MP accrual: 100% APR = 1 MP per LP token per year.
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

    /// @dev Combined vesting + fee reward delta for a time range
    function _pendingRewardDelta(
        uint256 fromTime,
        uint256 toTime
    ) internal view returns (uint256) {
        return _calculateVestingReward(fromTime, toTime) + _calculateFeeReward(fromTime, toTime);
    }

    /// @dev Calculate pending reward for a user using a cached accumulator value
    function _pendingReward(
        UserInfo memory user,
        uint256 _accRewardPerWeight
    ) internal pure returns (uint256) {
        uint256 weight = user.lpStaked + user.multiplierPoints;
        if (weight == 0) return 0;
        uint256 accumulated = weight * _accRewardPerWeight / PRECISION;
        return accumulated > user.rewardDebt ? accumulated - user.rewardDebt : 0;
    }

    // ============ View Functions ============

    /// @notice Get pending rewards for a user
    /// @param account User address
    /// @return Pending reward amount
    function pendingRewards(
        address account
    ) external view returns (uint256) {
        return _simulatePendingRewards(account);
    }

    /// @dev Simulate pending rewards
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

    /// @notice Get pool stats
    /// @return _totalLpStaked Total LP tokens staked across all users
    /// @return _totalWeight Total weight (LP + MP) across all stakers
    /// @return _vestingPerSecond Current vesting rate (0 after vesting ends)
    /// @return _vestingRemaining Remaining unvested tokens
    /// @return _currentEpochFees Fees being distributed in current epoch
    /// @return _feeRewardRate Current epoch fee distribution rate per second
    /// @return _pendingEpochFees Fees accumulated for next epoch
    /// @return _epochTimeRemaining Seconds until current epoch ends
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

    /// @notice Get user info with current multiplier points
    /// @param account User address to query
    /// @return stakedLp Amount of LP tokens staked
    /// @return currentMp Current multiplier points
    /// @return effectiveWeight Effective weight (stakedLp + currentMp)
    /// @return pending Pending reward amount
    /// @return poolShareBps User's share of the pool
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
        // Use simulated totalWeight to avoid >10000.
        uint256 simTotalWeight = totalWeight + (currentMp - user.multiplierPoints);
        poolShareBps = simTotalWeight > 0 ? effectiveWeight * 10000 / simTotalWeight : 0;
    }
}

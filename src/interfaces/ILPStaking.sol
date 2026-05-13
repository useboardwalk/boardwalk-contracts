// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface ILPStaking {
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
    event FeesLost(uint256 amount);
    event EpochAdvanced(uint256 epochStart, uint256 epochFees, uint256 feeRate);

    function setInitializer(
        address _initializer
    ) external;
    function initialize(
        address lpToken,
        address rewardToken,
        address feeDistributor,
        uint256 seedTime,
        uint256 vestingAllocation
    ) external;
    function stake(
        uint256 amount
    ) external;
    function withdraw(
        uint256 amount
    ) external;
    function claim() external returns (uint256 amount);
    function notifyFees(
        uint256 amount
    ) external;
    function pendingRewards(
        address account
    ) external view returns (uint256);
    function getPoolStats()
        external
        view
        returns (
            uint256 totalLpStaked,
            uint256 totalWeight,
            uint256 vestingPerSecond,
            uint256 vestingRemaining,
            uint256 currentEpochFees,
            uint256 feeRewardRate,
            uint256 pendingEpochFees,
            uint256 epochTimeRemaining
        );
    function getUserInfo(
        address account
    )
        external
        view
        returns (uint256 stakedLp, uint256 currentMp, uint256 effectiveWeight, uint256 pending, uint256 poolShareBps);
}

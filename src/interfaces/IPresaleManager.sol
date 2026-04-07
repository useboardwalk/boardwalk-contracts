// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IPresaleManager {
    error PresaleNotStarted();
    error PresaleEnded();
    error ZeroContribution();
    error AlreadyClaimed();
    error CliffNotEnded(uint256 cliffEnd, uint256 currentTime);
    error SeedTooEarly(uint256 seedableTime, uint256 currentTime);
    error AlreadySeeded();
    error BelowGraduationThreshold(uint256 raised, uint256 required);
    error AlreadyRefunded();
    error NoContribution();
    error PresaleNotFailed();
    error PresaleStillActive();
    error ZeroAddress();
    error InvalidDuration();
    error OnlyFactory();
    error ArrayLengthMismatch();
    error PairCreationFailed();
    error RouterFactoryMismatch();

    event Contributed(address indexed user, uint256 amount, uint256 bonusMultiplier);
    event TokensClaimed(address indexed user, uint256 amount);
    event PresaleInitialized(address token, uint256 presaleStart, uint256 presaleEnd, uint256 graduationThreshold);
    event VestingConfigSet(uint256 recipientCount);
    event LiquiditySeeded(uint256 raiseAmount, uint256 tokenAmount, uint256 lpTokens);
    event Refunded(address indexed user, uint256 amount);

    function initialize(
        address token,
        address feeDistributor,
        address vestingStream,
        address lpStaking,
        address router,
        address raiseToken,
        address dexFactory,
        uint256 duration,
        uint256 presalePercent,
        uint256 graduationThreshold,
        bool hasDelay
    ) external;
    function setVestingConfig(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external;
    function contribute(
        uint256 amount
    ) external;
    function seedLiquidity() external;
    function claimTokens() external;
    function refund() external;
    function calculateTokens(
        address account
    ) external view returns (uint256);
    function totalRaised() external view returns (uint256);
    function totalWeightedRaise() external view returns (uint256);
    function seeded() external view returns (bool);
    function presaleStart() external view returns (uint256);
    function presaleEnd() external view returns (uint256);
    function liquiditySeedTime() external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface ILaunchFactory {
    enum LaunchPath {
        EXPRESS,
        ADVANCED
    }

    struct LaunchConfig {
        string name;
        string ticker;
        string category;
        string description;
        LaunchPath path;
        uint256 presalePercent;
        address[] vestingRecipients;
        uint256[] vestingPercents;
        string[] vestingLabels;
        address referrer;
        address[] issuerFeeRecipients;
        uint256[] issuerFeeSplits;
        string[] issuerFeeLabels;
    }

    struct LaunchInfo {
        address token;
        address feeDistributor;
        address presaleManager;
        address vestingStream;
        address lpStaking;
        address issuer;
        LaunchPath path;
        uint32 createdAt;
    }

    struct FeeBpsDefaults {
        uint256 issuer;
        uint256 boardwalk;
        uint256 incentive;
        uint256 referrer;
        uint256 total;
    }

    error ReferrerNotAllowedOnExpressPath();
    error VestingNotAllowedOnExpressPath();
    error ExpressRequiresOneFeeRecipient();
    error InvalidPresalePercent(uint256 percent);
    error PresalePercentNotDivisibleBy5();
    error TooManyRecipients(uint256 count);
    error ArrayLengthMismatch();
    error InvalidSplitsSum();
    error ZeroAddress();
    error InvalidFeeDefaults();
    error InvalidAntiWhaleConfig();
    error BmxBurnOutOfRange(uint256 amount);
    error InvalidDuration();
    error InvalidPresaleRange(uint256 min, uint256 max);
    error ZeroGraduation();
    error IssuerVestingRecipientsRequired();
    error VestingNotAllowedAtFullPresale();
    error MemberDiscountOutOfRange(uint256 bps);
    error IntegratorCollectorMismatch();
    error DuplicateRoleAddress();

    event LaunchCreated(
        address indexed token,
        address indexed issuer,
        string name,
        string ticker,
        string category,
        string description,
        LaunchPath path,
        string[] issuerFeeLabels,
        string[] vestingLabels
    );
    event BmxBurnAmountChanged(uint256 oldAmount, uint256 newAmount);
    event GraduationThresholdChanged(LaunchPath path, uint256 oldThreshold, uint256 newThreshold);
    event PresaleDurationChanged(LaunchPath path, uint256 oldDuration, uint256 newDuration);
    event FeeDefaultsChanged(uint256 issuer, uint256 boardwalk, uint256 incentive, uint256 referrer);
    event PresaleRangeChanged(uint256 oldMin, uint256 oldMax, uint256 newMin, uint256 newMax);
    event FeeCollectorChanged(address oldCollector, address newCollector);
    event NftCollectionChanged(address oldCollection, address newCollection);
    event MemberLaunchDiscountChanged(uint256 oldDiscount, uint256 newDiscount);
    event AntiWhaleConfigChanged(uint256 oldTaxBps, uint256 oldDuration, uint256 newTaxBps, uint256 newDuration);

    function createLaunch(
        LaunchConfig calldata config
    ) external returns (address token);
    function launchCount() external view returns (uint256);
    function bmxBurnAmount() external view returns (uint256);
    function expressDuration() external view returns (uint256);
    function advancedDuration() external view returns (uint256);
    function minPresalePercent() external view returns (uint256);
    function maxPresalePercent() external view returns (uint256);
    function graduationExpress() external view returns (uint256);
    function graduationAdvanced() external view returns (uint256);
    function boardwalkFeeCollector() external view returns (address);
    function INTEGRATOR_COLLECTOR() external view returns (address);
    function INTEGRATOR_BPS() external view returns (uint256);
    function antiWhaleTaxBps() external view returns (uint256);
    function antiWhaleDuration() external view returns (uint256);
    function isLaunchToken(
        address token
    ) external view returns (bool);
    function nftCollection() external view returns (address);
    function memberLaunchDiscountBps() external view returns (uint256);
}

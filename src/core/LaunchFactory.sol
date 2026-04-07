// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Timelocked} from "../base/Timelocked.sol";
import {MembershipDiscount} from "../base/MembershipDiscount.sol";
import {AllocationLib} from "../base/AllocationLib.sol";
import {IBoardwalkToken} from "../interfaces/IBoardwalkToken.sol";
import {IFeeDistributor} from "../interfaces/IFeeDistributor.sol";
import {IPresaleManager} from "../interfaces/IPresaleManager.sol";
import {IVestingStream} from "../interfaces/IVestingStream.sol";
import {ILPStaking} from "../interfaces/ILPStaking.sol";

/// @title LaunchFactory - Singleton factory deploying token launches via EIP-1167 clones
/// @notice Handles BMX burn, config validation, clone deployment, and initialization of all per-launch contracts.
contract LaunchFactory is Ownable2Step, Timelocked, MembershipDiscount {
    using SafeERC20 for IERC20;

    // ============ Enums ============

    enum LaunchPath {
        EXPRESS,
        ADVANCED
    }

    // ============ Structs ============

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
        address integrator;
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
        uint256 integrator;
        uint256 total;
    }

    // ============ Constants ============

    uint256 private constant MAX_BMX_BURN = 200e18;
    uint256 private constant MAX_FEE_RECIPIENTS = 4;
    uint256 private constant MAX_VESTING_RECIPIENTS = 5;
    uint256 private constant MIN_ADVANCED_DURATION = 2 days;
    uint256 private constant MAX_ADVANCED_DURATION = 14 days;

    // Presale range hard limits
    uint256 private constant PRESALE_RANGE_FLOOR = 500;
    uint256 private constant PRESALE_RANGE_CEILING = 5000;
    uint256 private constant PRESALE_STEP = 500;

    // Fee component bounds
    uint256 private constant MIN_ISSUER_BPS = 10;
    uint256 private constant MAX_ISSUER_BPS = 80;
    uint256 private constant MIN_BOARDWALK_BPS = 10;
    uint256 private constant MAX_BOARDWALK_BPS = 50;
    uint256 private constant MAX_INCENTIVE_BPS = 50;
    uint256 private constant MAX_REFERRER_BPS = 10;
    uint256 private constant MAX_INTEGRATOR_BPS = 50;

    address public constant DEAD_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    // ============ Timelock Action Keys ============

    bytes32 public constant ACTION_SET_BMX_BURN = keccak256("SET_BMX_BURN");
    bytes32 public constant ACTION_SET_GRADUATION_EXPRESS = keccak256("SET_GRADUATION_EXPRESS");
    bytes32 public constant ACTION_SET_GRADUATION_ADVANCED = keccak256("SET_GRADUATION_ADVANCED");
    bytes32 public constant ACTION_SET_EXPRESS_DURATION = keccak256("SET_EXPRESS_DURATION");
    bytes32 public constant ACTION_SET_ADVANCED_DURATION = keccak256("SET_ADVANCED_DURATION");
    bytes32 public constant ACTION_SET_FEE_DEFAULTS = keccak256("SET_FEE_DEFAULTS");
    bytes32 public constant ACTION_SET_PRESALE_RANGE = keccak256("SET_PRESALE_RANGE");
    bytes32 public constant ACTION_SET_FEE_COLLECTOR = keccak256("SET_FEE_COLLECTOR");
    bytes32 public constant ACTION_SET_INTEGRATOR = keccak256("SET_INTEGRATOR");
    bytes32 public constant ACTION_SET_MEMBER_LAUNCH_DISCOUNT = keccak256("SET_MEMBER_LAUNCH_DISCOUNT");

    // ============ Immutables ============

    address public immutable TOKEN_IMPL;
    address public immutable FEE_DISTRIBUTOR_IMPL;
    address public immutable PRESALE_IMPL;
    address public immutable VESTING_IMPL;
    address public immutable LP_STAKING_IMPL;
    address public immutable BMX;
    address public immutable RAISE_TOKEN;
    address public immutable BOARDWALK_ROUTER;
    address public immutable BOARDWALK_DEX_FACTORY;
    address public immutable BOARDWALK_LP_MANAGER;

    // ============ State ============

    address public boardwalkFeeCollector;
    address public integrator;

    uint256 public bmxBurnAmount;

    uint256 public expressDuration;
    uint256 public advancedDuration;

    uint256 public minPresalePercent = 2500;
    uint256 public maxPresalePercent = 5000;

    uint256 public graduationExpress; // Graduation threshold for Express path
    uint256 public graduationAdvanced; // Graduation threshold for Advanced path

    uint256 public memberLaunchDiscountBps;

    FeeBpsDefaults private _feeBpsDefaults;

    // ============ Launch Registry ============

    mapping(address => LaunchInfo) public launches;
    address[] public allLaunches;

    // ============ Errors ============

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
    error BmxBurnOutOfRange(uint256 amount);
    error InvalidDuration();
    error InvalidPresaleRange(uint256 min, uint256 max);
    error ZeroGraduation();
    error IntegratorMismatch();
    error IntegratorNotAllowedWithReferrer();
    error IssuerVestingRecipientsRequired();
    error MemberDiscountOutOfRange(uint256 bps);

    // ============ Events ============

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
    event FeeDefaultsChanged(
        uint256 issuer, uint256 boardwalk, uint256 incentive, uint256 referrer, uint256 integrator
    );
    event PresaleRangeChanged(uint256 oldMin, uint256 oldMax, uint256 newMin, uint256 newMax);
    event FeeCollectorChanged(address oldCollector, address newCollector);
    event IntegratorChanged(address oldIntegrator, address newIntegrator);
    event MemberLaunchDiscountChanged(uint256 oldDiscount, uint256 newDiscount);

    // ============ Constructor ============

    struct DeployParams {
        address tokenImpl;
        address feeDistributorImpl;
        address presaleImpl;
        address vestingImpl;
        address lpStakingImpl;
        address bmx;
        address raiseToken;
        address boardwalkRouter;
        address boardwalkDexFactory;
        address boardwalkLpManager;
        address boardwalkFeeCollector;
        uint256 bmxBurnAmount;
        uint256 graduationExpress;
        uint256 graduationAdvanced;
        uint256 expressDuration;
        uint256 advancedDuration;
        FeeBpsDefaults feeBps;
        address nftCollection;
        uint256 memberLaunchDiscountBps;
    }

    constructor(
        address _owner,
        DeployParams memory p
    ) Ownable(_owner) {
        TOKEN_IMPL = p.tokenImpl;
        FEE_DISTRIBUTOR_IMPL = p.feeDistributorImpl;
        PRESALE_IMPL = p.presaleImpl;
        VESTING_IMPL = p.vestingImpl;
        LP_STAKING_IMPL = p.lpStakingImpl;
        BMX = p.bmx;
        RAISE_TOKEN = p.raiseToken;
        BOARDWALK_ROUTER = p.boardwalkRouter;
        BOARDWALK_DEX_FACTORY = p.boardwalkDexFactory;
        BOARDWALK_LP_MANAGER = p.boardwalkLpManager;
        boardwalkFeeCollector = p.boardwalkFeeCollector;
        if (p.bmxBurnAmount > MAX_BMX_BURN) revert BmxBurnOutOfRange(p.bmxBurnAmount);
        bmxBurnAmount = p.bmxBurnAmount;
        if (p.graduationExpress == 0 || p.graduationAdvanced == 0) revert ZeroGraduation();
        graduationExpress = p.graduationExpress;
        graduationAdvanced = p.graduationAdvanced;
        if (p.expressDuration == 0) revert InvalidDuration();
        if (p.advancedDuration < MIN_ADVANCED_DURATION || p.advancedDuration > MAX_ADVANCED_DURATION) {
            revert InvalidDuration();
        }
        expressDuration = p.expressDuration;
        advancedDuration = p.advancedDuration;

        _validateFeeDefaults(p.feeBps);
        _feeBpsDefaults = p.feeBps;

        if (p.memberLaunchDiscountBps > MAX_DISCOUNT_BPS) revert MemberDiscountOutOfRange(p.memberLaunchDiscountBps);
        memberLaunchDiscountBps = p.memberLaunchDiscountBps;
        _setNftCollection(p.nftCollection);
    }

    // ============ View Functions ============

    /// @notice Get the current fee BPS defaults
    function currentFeeBps()
        external
        view
        returns (
            uint256 issuer,
            uint256 boardwalk,
            uint256 incentive,
            uint256 referrer,
            uint256 integratorBps,
            uint256 total
        )
    {
        FeeBpsDefaults memory d = _feeBpsDefaults;
        return (d.issuer, d.boardwalk, d.incentive, d.referrer, d.integrator, d.total);
    }

    /// @notice Get the total number of launches
    function launchCount() external view returns (uint256) {
        return allLaunches.length;
    }

    /// @notice Check if a token address is a Boardwalk launch token from this factory
    function isLaunchToken(
        address token
    ) external view returns (bool) {
        return launches[token].token != address(0);
    }

    // ============ Launch Creation ============

    /// @notice Create a new token launch
    /// @param config Launch configuration
    /// @return tokenAddr Address of the deployed token clone
    function createLaunch(
        LaunchConfig calldata config
    ) external returns (address tokenAddr) {
        // Validate config
        _validateConfig(config);

        // BMX Burn (discounted for NFT members)
        uint256 effectiveBurn = _effectiveCost(bmxBurnAmount, memberLaunchDiscountBps, msg.sender);
        if (effectiveBurn > 0) {
            IERC20(BMX).safeTransferFrom(msg.sender, DEAD_ADDRESS, effectiveBurn);
        }

        // Deploy Clones
        tokenAddr = Clones.clone(TOKEN_IMPL);
        address feeDistributorAddr = Clones.clone(FEE_DISTRIBUTOR_IMPL);
        address presaleAddr = Clones.clone(PRESALE_IMPL);
        address lpStakingAddr = Clones.clone(LP_STAKING_IMPL);

        // Deploy VestingStream clone only if there are vesting recipients
        address vestingAddr;
        if (config.vestingRecipients.length > 0) {
            vestingAddr = Clones.clone(VESTING_IMPL);
        }

        // Lock Initializers
        // LPStaking and VestingStream are initialized by PresaleManager during seedLiquidity()
        ILPStaking(lpStakingAddr).setInitializer(presaleAddr);
        if (vestingAddr != address(0)) {
            IVestingStream(vestingAddr).setInitializer(presaleAddr, msg.sender);
        }

        // Build Exempt List
        uint256 exemptCount = vestingAddr != address(0) ? 5 : 4;
        address[] memory exemptAddresses = new address[](exemptCount);
        exemptAddresses[0] = presaleAddr;
        exemptAddresses[1] = lpStakingAddr;
        exemptAddresses[2] = BOARDWALK_LP_MANAGER;
        exemptAddresses[3] = boardwalkFeeCollector;
        if (exemptCount == 5) exemptAddresses[4] = vestingAddr;

        // Initialize Token
        FeeBpsDefaults memory feeBps = _feeBpsDefaults;

        IBoardwalkToken(tokenAddr)
            .initialize(config.name, config.ticker, feeBps.total, feeDistributorAddr, presaleAddr, exemptAddresses);

        // Initialize FeeDistributor (referrer fees carved from boardwalk)
        uint256 effectiveReferrerBps = config.referrer != address(0) ? feeBps.referrer : 0;
        uint256 effectiveBoardwalkBps = feeBps.boardwalk - effectiveReferrerBps;

        IFeeDistributor(feeDistributorAddr)
            .initialize(
                IFeeDistributor.InitParams({
                    token: tokenAddr,
                    lpStaking: lpStakingAddr,
                    feeCollector: boardwalkFeeCollector,
                    router: BOARDWALK_ROUTER,
                    raiseToken: RAISE_TOKEN,
                    issuerRecipients: config.issuerFeeRecipients,
                    issuerSplits: config.issuerFeeSplits,
                    referrer: config.referrer,
                    integrator: config.integrator,
                    issuerBps: feeBps.issuer,
                    boardwalkBps: effectiveBoardwalkBps,
                    lpIncentiveBps: feeBps.incentive,
                    referrerBps: effectiveReferrerBps,
                    integratorBps: feeBps.integrator
                })
            );

        // Determine Presale Parameters
        uint256 presaleDuration;
        uint256 presalePercent;
        uint256 graduationThreshold;
        bool hasDelay;

        if (config.path == LaunchPath.EXPRESS) {
            presaleDuration = expressDuration;
            presalePercent = 5000; // Express always 50%
            graduationThreshold = graduationExpress;
            hasDelay = false;
        } else {
            presaleDuration = advancedDuration;
            presalePercent = config.presalePercent;
            graduationThreshold = graduationAdvanced;
            hasDelay = true;
        }

        // Initialize PresaleManager
        IPresaleManager(presaleAddr)
            .initialize(
                tokenAddr,
                feeDistributorAddr,
                vestingAddr,
                lpStakingAddr,
                BOARDWALK_ROUTER,
                RAISE_TOKEN,
                BOARDWALK_DEX_FACTORY,
                presaleDuration,
                presalePercent,
                graduationThreshold,
                hasDelay
            );

        // Set Vesting Config on PresaleManager (if applicable)
        if (config.vestingRecipients.length > 0) {
            _setVestingConfig(config, presaleAddr, presalePercent);
        }

        // Register Launch
        LaunchInfo memory info = LaunchInfo({
            token: tokenAddr,
            feeDistributor: feeDistributorAddr,
            presaleManager: presaleAddr,
            vestingStream: vestingAddr,
            lpStaking: lpStakingAddr,
            issuer: msg.sender,
            path: config.path,
            createdAt: SafeCast.toUint32(block.timestamp)
        });

        launches[tokenAddr] = info;
        allLaunches.push(tokenAddr);

        emit LaunchCreated(
            tokenAddr,
            msg.sender,
            config.name,
            config.ticker,
            config.category,
            config.description,
            config.path,
            config.issuerFeeLabels,
            config.vestingLabels
        );
    }

    // ============ Vesting Amount Computation ============

    /// @dev Compute actual token amounts from user-supplied vesting percents and call setVestingConfig.
    ///      Uses the same allocation math as PresaleManager.seedLiquidity(). Total supply is 10 billion.
    function _setVestingConfig(
        LaunchConfig calldata config,
        address presaleAddr,
        uint256 presalePercent
    ) internal {
        (,,, uint256 issuerVestingTokens) = AllocationLib.compute(10_000_000_000e18, presalePercent);
        uint256[] memory vestingAmounts = AllocationLib.splitByBps(issuerVestingTokens, config.vestingPercents);
        IPresaleManager(presaleAddr).setVestingConfig(config.vestingRecipients, vestingAmounts);
    }

    // ============ Config Validation ============

    function _validateConfig(
        LaunchConfig calldata config
    ) internal view {
        // Array length checks
        if (
            config.issuerFeeRecipients.length != config.issuerFeeSplits.length
                || config.issuerFeeRecipients.length != config.issuerFeeLabels.length
        ) revert ArrayLengthMismatch();
        if (
            config.vestingRecipients.length != config.vestingPercents.length
                || config.vestingRecipients.length != config.vestingLabels.length
        ) revert ArrayLengthMismatch();

        // Fee recipient count
        uint256 feeRecipientCount = config.issuerFeeRecipients.length;
        if (feeRecipientCount == 0 || feeRecipientCount > MAX_FEE_RECIPIENTS) {
            revert TooManyRecipients(feeRecipientCount);
        }

        // Fee splits must sum to 10000
        uint256 feeSplitSum;
        for (uint256 i = 0; i < feeRecipientCount;) {
            if (config.issuerFeeRecipients[i] == address(0)) revert ZeroAddress();
            feeSplitSum += config.issuerFeeSplits[i];
            unchecked {
                ++i;
            }
        }
        if (feeSplitSum != AllocationLib.BPS_DENOMINATOR) revert InvalidSplitsSum();

        // Path-specific validation
        if (config.path == LaunchPath.EXPRESS) {
            if (config.referrer != address(0)) revert ReferrerNotAllowedOnExpressPath();
            if (config.vestingRecipients.length > 0) revert VestingNotAllowedOnExpressPath();
            if (feeRecipientCount != 1) revert ExpressRequiresOneFeeRecipient();
        } else {
            // ADVANCED path
            uint256 pp = config.presalePercent;
            if (pp < minPresalePercent || pp > maxPresalePercent) {
                revert InvalidPresalePercent(pp);
            }
            if (pp % PRESALE_STEP != 0) revert PresalePercentNotDivisibleBy5();

            // Advanced launches with presalePercent < 5000 MUST have vesting recipients
            if (pp < 5000 && config.vestingRecipients.length == 0) {
                revert IssuerVestingRecipientsRequired();
            }

            // Vesting validation
            if (config.vestingRecipients.length > MAX_VESTING_RECIPIENTS) {
                revert TooManyRecipients(config.vestingRecipients.length);
            }
            if (config.vestingRecipients.length > 0) {
                uint256 vestingSum;
                for (uint256 i = 0; i < config.vestingPercents.length;) {
                    vestingSum += config.vestingPercents[i];
                    unchecked {
                        ++i;
                    }
                }
                if (vestingSum != AllocationLib.BPS_DENOMINATOR) revert InvalidSplitsSum();
            }
        }

        // Integrator validation
        if (integrator != address(0)) {
            if (config.integrator != integrator) revert IntegratorMismatch();
            if (config.referrer != address(0)) revert IntegratorNotAllowedWithReferrer();
        } else {
            if (config.integrator != address(0)) revert IntegratorMismatch();
        }
    }

    // ============ Timelocked Admin Functions ============

    function _authAdmin(
        bytes32
    ) internal override onlyOwner {}

    /// @notice Execute a BMX burn amount change
    function executeSetBmxBurn(
        uint256 _amount
    ) external {
        _execute(ACTION_SET_BMX_BURN, keccak256(abi.encode(_amount)));
        if (_amount > MAX_BMX_BURN) revert BmxBurnOutOfRange(_amount);
        emit BmxBurnAmountChanged(bmxBurnAmount, _amount);
        bmxBurnAmount = _amount;
    }

    /// @notice Execute graduation threshold change for either path
    function executeSetGraduation(
        LaunchPath path,
        uint256 _threshold
    ) external {
        bytes32 action = path == LaunchPath.EXPRESS ? ACTION_SET_GRADUATION_EXPRESS : ACTION_SET_GRADUATION_ADVANCED;
        _execute(action, keccak256(abi.encode(_threshold)));
        if (_threshold == 0) revert ZeroGraduation();
        if (path == LaunchPath.EXPRESS) {
            emit GraduationThresholdChanged(LaunchPath.EXPRESS, graduationExpress, _threshold);
            graduationExpress = _threshold;
        } else {
            emit GraduationThresholdChanged(LaunchPath.ADVANCED, graduationAdvanced, _threshold);
            graduationAdvanced = _threshold;
        }
    }

    /// @notice Execute presale duration change for either path
    function executeSetDuration(
        LaunchPath path,
        uint256 _duration
    ) external {
        bytes32 action = path == LaunchPath.EXPRESS ? ACTION_SET_EXPRESS_DURATION : ACTION_SET_ADVANCED_DURATION;
        _execute(action, keccak256(abi.encode(_duration)));
        if (path == LaunchPath.EXPRESS) {
            if (_duration == 0) revert InvalidDuration();
            emit PresaleDurationChanged(LaunchPath.EXPRESS, expressDuration, _duration);
            expressDuration = _duration;
        } else {
            if (_duration < MIN_ADVANCED_DURATION || _duration > MAX_ADVANCED_DURATION) revert InvalidDuration();
            emit PresaleDurationChanged(LaunchPath.ADVANCED, advancedDuration, _duration);
            advancedDuration = _duration;
        }
    }

    /// @notice Execute fee defaults change
    function executeSetFeeDefaults(
        FeeBpsDefaults calldata _feeBps
    ) external {
        _execute(ACTION_SET_FEE_DEFAULTS, keccak256(abi.encode(_feeBps)));
        _validateFeeDefaults(_feeBps);
        _feeBpsDefaults = _feeBps;
        emit FeeDefaultsChanged(
            _feeBps.issuer, _feeBps.boardwalk, _feeBps.incentive, _feeBps.referrer, _feeBps.integrator
        );
    }

    /// @notice Execute presale percent range change
    function executeSetPresaleRange(
        uint256 _min,
        uint256 _max
    ) external {
        _execute(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(_min, _max)));
        _validatePresaleRange(_min, _max);
        emit PresaleRangeChanged(minPresalePercent, maxPresalePercent, _min, _max);
        minPresalePercent = _min;
        maxPresalePercent = _max;
    }

    /// @notice Execute fee collector address change
    function executeSetFeeCollector(
        address _collector
    ) external {
        _execute(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(_collector)));
        if (_collector == address(0)) revert ZeroAddress();
        emit FeeCollectorChanged(boardwalkFeeCollector, _collector);
        boardwalkFeeCollector = _collector;
    }

    /// @notice Execute integrator address change
    function executeSetIntegrator(
        address _integrator
    ) external {
        _execute(ACTION_SET_INTEGRATOR, keccak256(abi.encode(_integrator)));
        emit IntegratorChanged(integrator, _integrator);
        integrator = _integrator;
    }

    /// @notice Execute NFT collection address change
    function executeSetNftCollection(
        address _nft
    ) external {
        _execute(ACTION_SET_NFT_COLLECTION, keccak256(abi.encode(_nft)));
        _setNftCollection(_nft);
    }

    /// @notice Execute member launch discount BPS change
    function executeSetMemberLaunchDiscount(
        uint256 _bps
    ) external {
        _execute(ACTION_SET_MEMBER_LAUNCH_DISCOUNT, keccak256(abi.encode(_bps)));
        if (_bps > MAX_DISCOUNT_BPS) revert MemberDiscountOutOfRange(_bps);
        emit MemberLaunchDiscountChanged(memberLaunchDiscountBps, _bps);
        memberLaunchDiscountBps = _bps;
    }

    // ============ Internal Validation ============

    /// @dev Validate fee BPS defaults. Reverts with InvalidFeeDefaults on violation.
    function _validateFeeDefaults(
        FeeBpsDefaults memory d
    ) internal pure {
        // Total must equal issuer + boardwalk + incentive + integrator (referrer excluded; carved from boardwalk)
        if (d.total != d.issuer + d.boardwalk + d.incentive + d.integrator) revert InvalidFeeDefaults();

        if (d.issuer < MIN_ISSUER_BPS || d.issuer > MAX_ISSUER_BPS) revert InvalidFeeDefaults();
        if (d.boardwalk < MIN_BOARDWALK_BPS || d.boardwalk > MAX_BOARDWALK_BPS) revert InvalidFeeDefaults();
        if (d.incentive > MAX_INCENTIVE_BPS) revert InvalidFeeDefaults();
        if (d.referrer > MAX_REFERRER_BPS) revert InvalidFeeDefaults();
        if (d.integrator > MAX_INTEGRATOR_BPS) revert InvalidFeeDefaults();

        // Referrer carved from boardwalk share
        if (d.referrer > d.boardwalk) revert InvalidFeeDefaults();

        // Referrer and integrator are mutually exclusive
        if (d.referrer > 0 && d.integrator > 0) revert InvalidFeeDefaults();
    }

    /// @dev Validate presale range parameters
    function _validatePresaleRange(
        uint256 _min,
        uint256 _max
    ) internal pure {
        if (
            _min < PRESALE_RANGE_FLOOR || _max > PRESALE_RANGE_CEILING || _min > _max || _min % PRESALE_STEP != 0
                || _max % PRESALE_STEP != 0
        ) {
            revert InvalidPresaleRange(_min, _max);
        }
    }
}

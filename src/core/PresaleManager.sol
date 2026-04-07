// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IBoardwalkToken} from "../interfaces/IBoardwalkToken.sol";
import {ILPStaking} from "../interfaces/ILPStaking.sol";
import {IVestingStream} from "../interfaces/IVestingStream.sol";
import {IDEXRouter} from "../interfaces/IDEXRouter.sol";
import {IDEXFactory} from "../interfaces/IDEXFactory.sol";
import {IUniswapV2Pair} from "../dex/core/interfaces/IUniswapV2Pair.sol";
import {AllocationLib} from "../base/AllocationLib.sol";

/// @title PresaleManager - Handles raise token contributions, liquidity seeding, token claims, and refunds
/// @notice Per-launch clone. Collects raise token during presale, seeds permanent liquidity on graduation,
///         and allows presale participants to claim tokens after 7-day cliff.
contract PresaleManager is Initializable {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 public constant TOTAL_SUPPLY = 10_000_000_000e18; // 10 billion tokens
    uint256 public constant SEED_DELAY = 1 hours;
    uint256 public constant CLIFF_DURATION = 7 days;
    uint256 public constant ADVANCED_START_DELAY = 24 hours;
    address public constant DEAD_ADDRESS = address(0x000000000000000000000000000000000000dEaD);
    uint256 private constant MAX_BONUS_BPS = 1_000;

    // ============ State ============

    // Core addresses
    address public token;
    address public feeDistributor;
    address public vestingStream;
    address public lpStaking;
    address public router;
    IERC20 public raiseToken;
    address public dexFactory;
    address public factory; // LaunchFactory address (for access control on setVestingConfig)

    // Presale config
    uint256 public presaleStart;
    uint256 public presaleEnd;
    uint256 public presaleDuration;
    uint256 public presalePercent; // BPS (2500-5000)
    uint256 public graduationThreshold;

    // Presale state
    uint256 public totalRaised;
    uint256 public totalWeightedRaise;
    uint256 public liquiditySeedTime;
    bool public seeded;

    // Vesting config (stored for use during seedLiquidity)
    address[] private _vestingRecipients;
    uint256[] private _vestingAmounts;

    // Per-user tracking
    struct UserContribution {
        uint256 totalContributed;
        uint256 weightedContributed;
    }

    mapping(address => UserContribution) public contributions;
    mapping(address => bool) public claimed;
    mapping(address => bool) public refunded;

    // ============ Errors ============

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

    // ============ Events ============

    event Contributed(address indexed user, uint256 amount, uint256 bonusMultiplier);
    event TokensClaimed(address indexed user, uint256 amount);
    event LiquiditySeeded(uint256 raiseAmount, uint256 tokenAmount, uint256 lpTokens);
    event Refunded(address indexed user, uint256 amount);
    event PresaleInitialized(address token, uint256 presaleStart, uint256 presaleEnd, uint256 graduationThreshold);
    event VestingConfigSet(uint256 recipientCount);

    // ============ Constructor ============

    /// @dev Disable initialization on the implementation template
    constructor() {
        _disableInitializers();
    }

    // ============ Initialization ============

    /// @notice Initialize the PresaleManager clone
    /// @param _token BoardwalkToken clone address
    /// @param _feeDistributor FeeDistributor clone address
    /// @param _vestingStreamAddr VestingStream clone address (address(0) for Express path)
    /// @param _lpStaking LPStaking clone address
    /// @param _router BoardwalkRouter address
    /// @param _raiseToken Raise token address
    /// @param _dexFactory BoardwalkDEXFactory address
    /// @param _duration Presale duration in seconds
    /// @param _presalePercent Presale percentage in BPS (2500-5000)
    /// @param _graduationThreshold Minimum raise token for graduation
    /// @param _hasDelay Whether presale starts with 24hr delay (Advanced path)
    function initialize(
        address _token,
        address _feeDistributor,
        address _vestingStreamAddr,
        address _lpStaking,
        address _router,
        address _raiseToken,
        address _dexFactory,
        uint256 _duration,
        uint256 _presalePercent,
        uint256 _graduationThreshold,
        bool _hasDelay
    ) external initializer {
        if (_token == address(0)) revert ZeroAddress();
        if (_feeDistributor == address(0)) revert ZeroAddress();
        if (_lpStaking == address(0)) revert ZeroAddress();
        if (_router == address(0)) revert ZeroAddress();
        if (_raiseToken == address(0)) revert ZeroAddress();
        if (_dexFactory == address(0)) revert ZeroAddress();
        if (_duration == 0) revert InvalidDuration();

        // Verify router and factory are paired
        if (IDEXRouter(_router).factory() != _dexFactory) revert RouterFactoryMismatch();

        factory = msg.sender; // Store factory address for setVestingConfig access control
        token = _token;
        feeDistributor = _feeDistributor;
        vestingStream = _vestingStreamAddr;
        lpStaking = _lpStaking;
        router = _router;
        raiseToken = IERC20(_raiseToken);
        dexFactory = _dexFactory;

        presaleDuration = _duration;
        presalePercent = _presalePercent;
        graduationThreshold = _graduationThreshold;

        // Express: starts immediately. Advanced: 24hr delay.
        if (_hasDelay) {
            presaleStart = block.timestamp + ADVANCED_START_DELAY;
        } else {
            presaleStart = block.timestamp;
        }
        presaleEnd = presaleStart + _duration;

        emit PresaleInitialized(_token, presaleStart, presaleEnd, _graduationThreshold);
    }

    /// @notice Store vesting config (called by factory after initialize, before presale starts)
    /// @dev Separate from initialize to avoid stack-too-deep. Only factory can call.
    /// @param recipients Array of vesting recipient addresses
    /// @param amounts Array of token amounts for each recipient
    function setVestingConfig(
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (_vestingRecipients.length > 0) revert InvalidInitialization();
        if (recipients.length != amounts.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < recipients.length;) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            _vestingRecipients.push(recipients[i]);
            _vestingAmounts.push(amounts[i]);
            unchecked {
                ++i;
            }
        }

        emit VestingConfigSet(recipients.length);
    }

    // ============ Contribution ============

    /// @notice Contribute raise token to the presale
    /// @param amount Amount of raise token to contribute
    function contribute(
        uint256 amount
    ) external {
        uint256 _presaleStart = presaleStart;
        if (block.timestamp < _presaleStart) revert PresaleNotStarted();
        if (block.timestamp >= presaleEnd) revert PresaleEnded();
        if (amount == 0) revert ZeroContribution();

        raiseToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 timeElapsed = block.timestamp - _presaleStart;
        uint256 bonusMultiplier =
            AllocationLib.BPS_DENOMINATOR + (MAX_BONUS_BPS * (presaleDuration - timeElapsed) / presaleDuration);

        uint256 weightedAmount = amount * bonusMultiplier / AllocationLib.BPS_DENOMINATOR;

        UserContribution storage user = contributions[msg.sender];
        user.totalContributed += amount;
        user.weightedContributed += weightedAmount;

        totalRaised += amount;
        totalWeightedRaise += weightedAmount;

        emit Contributed(msg.sender, amount, bonusMultiplier);
    }

    // ============ Liquidity Seeding ============

    /// @notice Seed liquidity after presale ends + 1 hour. Public function, anyone can call.
    /// @dev Mints tokens, creates LP, burns LP tokens, initializes LPStaking and VestingStream.
    function seedLiquidity() external {
        if (block.timestamp < presaleEnd + SEED_DELAY) {
            revert SeedTooEarly(presaleEnd + SEED_DELAY, block.timestamp);
        }
        if (seeded) revert AlreadySeeded();
        if (totalRaised < graduationThreshold) {
            revert BelowGraduationThreshold(totalRaised, graduationThreshold);
        }

        seeded = true;
        liquiditySeedTime = block.timestamp;

        (uint256 presaleTokens, uint256 liquidityTokens, uint256 lpIncentiveTokens, uint256 issuerVestingTokens) =
            AllocationLib.compute(TOTAL_SUPPLY, presalePercent);

        IBoardwalkToken(token).mint(address(this), presaleTokens + liquidityTokens);
        if (lpIncentiveTokens > 0) {
            IBoardwalkToken(token).mint(lpStaking, lpIncentiveTokens);
        }
        if (issuerVestingTokens > 0 && vestingStream != address(0)) {
            IBoardwalkToken(token).mint(vestingStream, issuerVestingTokens);
        }

        // Get or create pair
        address pair = IDEXFactory(dexFactory).getPair(token, address(raiseToken));
        if (pair == address(0)) {
            pair = IDEXFactory(dexFactory).createPair(token, address(raiseToken));
            if (pair == address(0)) revert PairCreationFailed();
        }

        // Seed initial liquidity by minting directly on the pair.
        IERC20(token).safeTransfer(pair, liquidityTokens);
        raiseToken.safeTransfer(pair, totalRaised);
        uint256 lpTokens = IUniswapV2Pair(pair).mint(address(this));

        IERC20(pair).safeTransfer(DEAD_ADDRESS, lpTokens);

        ILPStaking(lpStaking).initialize(pair, token, feeDistributor, liquiditySeedTime, lpIncentiveTokens);

        if (vestingStream != address(0) && issuerVestingTokens > 0 && _vestingRecipients.length > 0) {
            IVestingStream(vestingStream).initialize(token, liquiditySeedTime, _vestingRecipients, _vestingAmounts);
        }

        IBoardwalkToken(token).setLiquiditySeedTime(liquiditySeedTime);

        emit LiquiditySeeded(totalRaised, liquidityTokens, lpTokens);
    }

    // ============ Token Claims ============

    /// @notice Claim presale tokens after 7-day cliff
    function claimTokens() external {
        if (!seeded) revert PresaleNotStarted();
        if (block.timestamp < liquiditySeedTime + CLIFF_DURATION) {
            revert CliffNotEnded(liquiditySeedTime + CLIFF_DURATION, block.timestamp);
        }
        if (claimed[msg.sender]) revert AlreadyClaimed();

        uint256 tokenAmount = calculateTokens(msg.sender);
        if (tokenAmount == 0) revert NoContribution();

        claimed[msg.sender] = true;

        // Transfer tokens (PresaleManager is exempt from tax)
        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        emit TokensClaimed(msg.sender, tokenAmount);
    }

    // ============ Refunds ============

    /// @notice Refund raise token if presale failed to graduate
    function refund() external {
        // Must be after presale + seed delay
        if (block.timestamp < presaleEnd + SEED_DELAY) {
            revert PresaleStillActive();
        }
        // Must not have been seeded (i.e., presale failed)
        if (seeded) revert AlreadySeeded();
        // Below graduation threshold = failed
        if (totalRaised >= graduationThreshold) revert PresaleNotFailed();
        if (refunded[msg.sender]) revert AlreadyRefunded();

        UserContribution memory user = contributions[msg.sender];
        if (user.totalContributed == 0) revert NoContribution();

        refunded[msg.sender] = true;

        raiseToken.safeTransfer(msg.sender, user.totalContributed);

        emit Refunded(msg.sender, user.totalContributed);
    }

    // ============ View Functions ============

    /// @notice Calculate token amount for a contributor
    /// @param account Contributor address
    /// @return Token amount claimable
    function calculateTokens(
        address account
    ) public view returns (uint256) {
        UserContribution memory user = contributions[account];
        if (user.weightedContributed == 0 || totalWeightedRaise == 0) return 0;

        uint256 presaleTokens = TOTAL_SUPPLY * presalePercent / AllocationLib.BPS_DENOMINATOR;
        return user.weightedContributed * presaleTokens / totalWeightedRaise;
    }

    /// @notice Check if presale has failed (below threshold after deadline)
    function hasFailed() external view returns (bool) {
        if (seeded) return false;
        if (block.timestamp < presaleEnd + SEED_DELAY) return false;
        return totalRaised < graduationThreshold;
    }

    /// @notice Get the cliff end time (0 if not yet seeded)
    function cliffEnd() external view returns (uint256) {
        if (liquiditySeedTime == 0) return 0;
        return liquiditySeedTime + CLIFF_DURATION;
    }
}


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

/// @title PresaleManager
/// @notice Per-launch clone. Collects raise token, seeds permanent liquidity on graduation, and pays
///         out presale claims after a 7-day cliff. Refunds if the threshold isn't met.
contract PresaleManager is Initializable {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 10_000_000_000e18;
    uint256 public constant SEED_DELAY = 1 hours;
    uint256 public constant CLIFF_DURATION = 7 days;
    uint256 public constant ADVANCED_START_DELAY = 24 hours;
    address public constant DEAD_ADDRESS = address(0x000000000000000000000000000000000000dEaD);
    uint256 private constant MAX_BONUS_BPS = 1_000;

    address public token;
    address public feeDistributor;
    address public vestingStream;
    address public lpStaking;
    address public router;
    IERC20 public raiseToken;
    address public dexFactory;
    address public factory;

    uint256 public presaleStart;
    uint256 public presaleEnd;
    uint256 public presaleDuration;
    uint256 public presalePercent;
    uint256 public graduationThreshold;

    uint256 public totalRaised;
    uint256 public totalWeightedRaise;
    uint256 public liquiditySeedTime;
    bool public seeded;

    address[] private _vestingRecipients;
    uint256[] private _vestingAmounts;

    struct UserContribution {
        uint256 totalContributed;
        uint256 weightedContributed;
    }

    mapping(address => UserContribution) public contributions;
    mapping(address => bool) public claimed;
    mapping(address => bool) public refunded;

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
    event LiquiditySeeded(uint256 raiseAmount, uint256 tokenAmount, uint256 lpTokens);
    event Refunded(address indexed user, uint256 amount);
    event PresaleInitialized(address token, uint256 presaleStart, uint256 presaleEnd, uint256 graduationThreshold);
    event VestingConfigSet(uint256 recipientCount);

    constructor() {
        _disableInitializers();
    }

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

        if (IDEXRouter(_router).factory() != _dexFactory) revert RouterFactoryMismatch();

        factory = msg.sender;
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

        presaleStart = _hasDelay ? block.timestamp + ADVANCED_START_DELAY : block.timestamp;
        presaleEnd = presaleStart + _duration;

        emit PresaleInitialized(_token, presaleStart, presaleEnd, _graduationThreshold);
    }

    /// @notice Store vesting recipients and amounts. Factory-only, one-shot.
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

    /// @notice Contribute raise token to the presale. Time-decay bonus: +10% at start → 0% at end.
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

    /// @notice Permissionless after `presaleEnd + SEED_DELAY` if the graduation threshold is met.
    ///         Mints all token buckets, seeds the pair, burns LP to dead, initialises LPStaking and
    ///         VestingStream, and arms the anti-whale tax decay.
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

        address pair = IDEXFactory(dexFactory).getPair(token, address(raiseToken));
        if (pair == address(0)) {
            pair = IDEXFactory(dexFactory).createPair(token, address(raiseToken));
            if (pair == address(0)) revert PairCreationFailed();
        }

        // Seed liquidity by transferring directly to the pair and calling mint — no router needed.
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

    /// @notice Claim presale tokens after the 7-day cliff.
    function claimTokens() external {
        if (!seeded) revert PresaleNotStarted();
        if (block.timestamp < liquiditySeedTime + CLIFF_DURATION) {
            revert CliffNotEnded(liquiditySeedTime + CLIFF_DURATION, block.timestamp);
        }
        if (claimed[msg.sender]) revert AlreadyClaimed();

        uint256 tokenAmount = calculateTokens(msg.sender);
        if (tokenAmount == 0) revert NoContribution();

        claimed[msg.sender] = true;

        IERC20(token).safeTransfer(msg.sender, tokenAmount);

        emit TokensClaimed(msg.sender, tokenAmount);
    }

    /// @notice Refund raise token contributions when the presale failed to meet `graduationThreshold`.
    function refund() external {
        if (block.timestamp < presaleEnd + SEED_DELAY) {
            revert PresaleStillActive();
        }
        if (seeded) revert AlreadySeeded();
        if (totalRaised >= graduationThreshold) revert PresaleNotFailed();
        if (refunded[msg.sender]) revert AlreadyRefunded();

        UserContribution memory user = contributions[msg.sender];
        if (user.totalContributed == 0) revert NoContribution();

        refunded[msg.sender] = true;

        raiseToken.safeTransfer(msg.sender, user.totalContributed);

        emit Refunded(msg.sender, user.totalContributed);
    }

    function calculateTokens(
        address account
    ) public view returns (uint256) {
        UserContribution memory user = contributions[account];
        if (user.weightedContributed == 0 || totalWeightedRaise == 0) return 0;

        uint256 presaleTokens = TOTAL_SUPPLY * presalePercent / AllocationLib.BPS_DENOMINATOR;
        return user.weightedContributed * presaleTokens / totalWeightedRaise;
    }

    function hasFailed() external view returns (bool) {
        if (seeded) return false;
        if (block.timestamp < presaleEnd + SEED_DELAY) return false;
        return totalRaised < graduationThreshold;
    }

    function cliffEnd() external view returns (uint256) {
        if (liquiditySeedTime == 0) return 0;
        return liquiditySeedTime + CLIFF_DURATION;
    }
}


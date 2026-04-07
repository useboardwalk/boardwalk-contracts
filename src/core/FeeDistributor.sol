// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Timelocked} from "../base/Timelocked.sol";
import {ILPStaking} from "../interfaces/ILPStaking.sol";
import {IBoardwalkFeeCollector} from "../interfaces/IBoardwalkFeeCollector.sol";
import {IBoardwalkToken} from "../interfaces/IBoardwalkToken.sol";
import {IDEXRouter} from "../interfaces/IDEXRouter.sol";

/// @title FeeDistributor - Routes token tax to LP staking, Boardwalk, issuer, referrer, and integrator
/// @notice Per-launch clone. Receives tax via onTaxReceived callback from BoardwalkToken.
///         Splits by configured BPS and forwards LP/Boardwalk shares immediately.
///         Issuer claims as raise token with rate limit. Referrer/integrator claim in native token.
/// @dev Inherits Timelocked but blocks generic signalAction/cancelAction/signalBurnAction via
///      _authAdmin (always reverts). Uses typed per-recipient signal/execute/cancel flows instead.
///      The generic Timelocked public functions appear on the ABI but are non-functional.
contract FeeDistributor is Timelocked, Initializable {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    uint256 private constant BPS_DENOMINATOR = 10_000;

    bytes32 public constant ACTION_CHANGE_ISSUER = keccak256("CHANGE_ISSUER");
    bytes32 public constant ACTION_CHANGE_REFERRER = keccak256("CHANGE_REFERRER");

    // ============ Immutable Config (set at initialization) ============

    address public token;
    address public lpStaking;
    address public feeCollector;
    address public router;
    address public raiseToken;

    // Fee BPS
    uint256 public issuerBps;
    uint256 public boardwalkBps;
    uint256 public lpIncentiveBps;
    uint256 public referrerBps;
    uint256 public integratorBps;
    uint256 public totalFeeBps;

    // ============ Recipient State ============

    address[] public issuerRecipients; // Issuer fee recipients (up to 4)
    uint256[] public issuerSplits; // Each split as BPS of issuer share (sum = 10000)

    address public referrer; // Address(0) if no referrer
    address public integrator; // Address(0) if no integrator

    // ============ Accrued Fee Tracking ============

    struct ClaimState {
        uint256 totalAccrued;
        uint256 totalClaimed;
        uint256 claimedInCurrentPeriod;
        uint64 lastClaimTime;
    }

    /// @notice Independent claim state per issuer recipient
    mapping(uint256 => ClaimState) public issuerClaimStates;

    /// @notice Total accrued referrer fees (claimable in native token)
    uint256 public referrerAccrued;
    uint256 public referrerClaimed;

    /// @notice Total accrued integrator fees (claimable in native token)
    uint256 public integratorAccrued;
    uint256 public integratorClaimed;

    /// @notice Pending fees from failed forwards (retryable via retryPendingFees)
    uint256 public pendingLpFees;
    uint256 public pendingBoardwalkFees;

    // ============ Initialization ============

    struct InitParams {
        address token;
        address lpStaking;
        address feeCollector;
        address router;
        address raiseToken;
        address[] issuerRecipients;
        uint256[] issuerSplits;
        address referrer;
        address integrator;
        uint256 issuerBps;
        uint256 boardwalkBps;
        uint256 lpIncentiveBps;
        uint256 referrerBps;
        uint256 integratorBps;
    }

    // ============ Errors ============

    error OnlyToken();
    error NotRecipient();
    error NothingToClaimYet();
    error ZeroAddress();
    error InvalidFeeBps();
    error InvalidSplitsSum();
    error ArrayLengthMismatch();
    error OnlyFeeCollector();
    error NotIntegrator();
    error NotAuthorized();

    // ============ Events ============

    event TaxReceived(
        uint256 amount,
        uint256 lpShare,
        uint256 boardwalkShare,
        uint256 issuerShare,
        uint256 referrerShare,
        uint256 integratorShare
    );
    event IssuerClaimed(
        uint256 indexed recipientIdx, address indexed recipient, uint256 tokenAmount, uint256 raiseTokenAmount
    );
    event ReferrerClaimed(address indexed referrer, uint256 amount);
    event IntegratorClaimed(address indexed integrator, uint256 amount);
    event FeeForwardFailed(string target, uint256 amount);
    event FeeCollectorChanged(address oldCollector, address newCollector);
    event IssuerAddressChanged(uint256 indexed recipientIdx, address oldAddress, address newAddress);
    event ReferrerAddressChanged(address oldAddress, address newAddress);

    // ============ Constructor ============

    /// @dev Disable initialization on the implementation template
    constructor() {
        _disableInitializers();
    }

    // ============ Initialize ============

    /// @notice Initialize the FeeDistributor clone
    /// @param p Initialization parameters struct
    function initialize(
        InitParams calldata p
    ) external initializer {
        if (p.token == address(0)) revert ZeroAddress();
        if (p.lpStaking == address(0)) revert ZeroAddress();
        if (p.feeCollector == address(0)) revert ZeroAddress();
        if (p.router == address(0)) revert ZeroAddress();
        if (p.raiseToken == address(0)) revert ZeroAddress();

        if (p.issuerRecipients.length != p.issuerSplits.length) revert ArrayLengthMismatch();
        if (p.issuerRecipients.length == 0) revert ArrayLengthMismatch();

        // Validate splits sum to 10000
        uint256 splitsSum;
        for (uint256 i = 0; i < p.issuerSplits.length;) {
            splitsSum += p.issuerSplits[i];
            if (p.issuerRecipients[i] == address(0)) revert ZeroAddress();
            unchecked {
                ++i;
            }
        }
        if (splitsSum != BPS_DENOMINATOR) revert InvalidSplitsSum();

        // Validate fee BPS
        uint256 _totalFeeBps = p.issuerBps + p.boardwalkBps + p.lpIncentiveBps + p.referrerBps + p.integratorBps;
        if (_totalFeeBps == 0) revert InvalidFeeBps();
        if (p.integrator == address(0) && p.integratorBps > 0) revert InvalidFeeBps();

        token = p.token;
        lpStaking = p.lpStaking;
        feeCollector = p.feeCollector;
        router = p.router;
        raiseToken = p.raiseToken;

        issuerBps = p.issuerBps;
        boardwalkBps = p.boardwalkBps;
        lpIncentiveBps = p.lpIncentiveBps;
        referrerBps = p.referrerBps;
        integratorBps = p.integratorBps;
        totalFeeBps = _totalFeeBps;

        // Store recipients
        for (uint256 i = 0; i < p.issuerRecipients.length;) {
            issuerRecipients.push(p.issuerRecipients[i]);
            issuerSplits.push(p.issuerSplits[i]);
            unchecked {
                ++i;
            }
        }

        referrer = p.referrer;
        integrator = p.integrator;

        // Approve LPStaking, FeeCollector, and Router to spend tokens
        // LPStaking pulls via notifyFees
        // FeeCollector pulls via receiveFees
        // Router pulls during issuer raise token claim swaps
        IERC20(p.token).approve(p.lpStaking, type(uint256).max);
        IERC20(p.token).approve(p.feeCollector, type(uint256).max);
        IERC20(p.token).approve(p.router, type(uint256).max);
    }

    // ============ Tax Callback ============

    /// @notice Called by BoardwalkToken on every taxed transfer to split and forward fees
    /// @dev Splits tax amount by configured BPS. LP and Boardwalk shares forwarded with try/catch safety net.
    /// @param amount Total tax amount received from token
    function onTaxReceived(
        uint256 amount
    ) external {
        if (msg.sender != token) revert OnlyToken();

        uint256 _totalFeeBps = totalFeeBps;
        uint256 lpShare = amount * lpIncentiveBps / _totalFeeBps;
        uint256 boardwalkShare = amount * boardwalkBps / _totalFeeBps;
        uint256 referrerShare = (referrer != address(0)) ? amount * referrerBps / _totalFeeBps : 0;
        uint256 integratorShare = (integrator != address(0)) ? amount * integratorBps / _totalFeeBps : 0;
        uint256 issuerShare = amount - lpShare - boardwalkShare - referrerShare - integratorShare;

        if (lpShare > 0) _forwardLpFees(lpShare);
        if (boardwalkShare > 0) _forwardBoardwalkFees(boardwalkShare);

        // Accrue issuer fees
        if (issuerShare > 0) {
            _accrueIssuerFees(issuerShare);
        }

        if (referrerShare > 0) {
            referrerAccrued += referrerShare;
        }

        if (integratorShare > 0) {
            integratorAccrued += integratorShare;
        }

        emit TaxReceived(amount, lpShare, boardwalkShare, issuerShare, referrerShare, integratorShare);
    }

    // ============ Fee Retry ============

    /// @notice Retry forwarding any fees that failed during onTaxReceived. Anyone can call.
    function retryPendingFees() external {
        uint256 lpAmount = pendingLpFees;
        if (lpAmount > 0) {
            pendingLpFees = 0;
            _forwardLpFees(lpAmount);
        }
        uint256 bwAmount = pendingBoardwalkFees;
        if (bwAmount > 0) {
            pendingBoardwalkFees = 0;
            _forwardBoardwalkFees(bwAmount);
        }
    }

    // ============ Issuer Claim ============

    /// @notice Issuer recipient claims accrued fees as raise token via native LP swap
    /// @dev Rate limited: 10% of total accrued per 24-hour period, per recipient.
    /// @param recipientIdx Index of the issuer recipient (0-3)
    /// @param minRaiseTokenOut Minimum raise token output for slippage protection
    /// @param deadline Transaction deadline (MEV protection)
    function claimAsRaiseToken(
        uint256 recipientIdx,
        uint256 minRaiseTokenOut,
        uint256 deadline
    ) external {
        if (msg.sender != issuerRecipients[recipientIdx]) revert NotRecipient();

        uint256 tokenAmount = claimableAmount(recipientIdx);
        if (tokenAmount == 0) revert NothingToClaimYet();

        _updateClaimState(recipientIdx, tokenAmount);

        // Router has max approval from initialize
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = raiseToken;

        uint256[] memory amounts =
            IDEXRouter(router).swapExactTokensForTokens(tokenAmount, minRaiseTokenOut, path, msg.sender, deadline);

        emit IssuerClaimed(recipientIdx, msg.sender, tokenAmount, amounts[1]);
    }

    /// @notice Get the claimable amount for an issuer recipient (respects rate limit)
    /// @param recipientIdx Index of the issuer recipient
    /// @return Claimable token amount
    function claimableAmount(
        uint256 recipientIdx
    ) public view returns (uint256) {
        ClaimState memory state = issuerClaimStates[recipientIdx];
        if (state.totalAccrued == 0) return 0;

        uint256 unclaimed = state.totalAccrued - state.totalClaimed;
        if (unclaimed == 0) return 0;

        uint256 maxClaimable = state.totalAccrued / 10; // 10% of total accrued

        // Dust escape: if rate-limit rounds to zero, allow claiming full remaining amount
        if (maxClaimable == 0) return unclaimed;

        if (block.timestamp >= state.lastClaimTime + 1 days) {
            // New period - can claim up to 10% of total accrued
            return _min(maxClaimable, unclaimed);
        }

        // Same period - subtract what's already claimed this period
        if (state.claimedInCurrentPeriod >= maxClaimable) return 0;
        uint256 remainingInPeriod = maxClaimable - state.claimedInCurrentPeriod;
        return _min(remainingInPeriod, unclaimed);
    }

    // ============ Referrer Claim ============

    /// @notice Referrer claims accrued fees in native token (no rate limit)
    function claimReferrerFees() external {
        if (msg.sender != referrer) revert NotRecipient();
        uint256 amount = _validateThirdPartyClaim(referrerAccrued, referrerClaimed);
        referrerClaimed += amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit ReferrerClaimed(msg.sender, amount);
    }

    // ============ Integrator Claim ============

    /// @notice Integrator claims accrued fees in native token (no rate limit)
    function claimIntegratorFees() external {
        if (msg.sender != integrator) revert NotIntegrator();
        uint256 amount = _validateThirdPartyClaim(integratorAccrued, integratorClaimed);
        integratorClaimed += amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit IntegratorClaimed(msg.sender, amount);
    }

    // ============ Timelocked Address Changes ============

    /// @notice Signal issuer address change. Only current recipient.
    function signalChangeIssuerAddress(
        uint256 recipientIdx,
        address newAddress
    ) external {
        if (msg.sender != issuerRecipients[recipientIdx]) revert NotRecipient();
        bytes32 action = keccak256(abi.encode(ACTION_CHANGE_ISSUER, recipientIdx));
        _signal(action, keccak256(abi.encode(newAddress)));
    }

    /// @notice Execute issuer address change. Permissionless after delay.
    function executeChangeIssuerAddress(
        uint256 recipientIdx,
        address newAddress
    ) external {
        bytes32 action = keccak256(abi.encode(ACTION_CHANGE_ISSUER, recipientIdx));
        _execute(action, keccak256(abi.encode(newAddress)));
        if (newAddress == address(0)) revert ZeroAddress();
        emit IssuerAddressChanged(recipientIdx, issuerRecipients[recipientIdx], newAddress);
        issuerRecipients[recipientIdx] = newAddress;
    }

    /// @notice Cancel pending issuer address change. Only current recipient.
    function cancelChangeIssuerAddress(
        uint256 recipientIdx
    ) external {
        if (msg.sender != issuerRecipients[recipientIdx]) revert NotRecipient();
        bytes32 action = keccak256(abi.encode(ACTION_CHANGE_ISSUER, recipientIdx));
        _cancel(action);
    }

    /// @notice Signal referrer address change.
    /// @param newAddress New referrer address
    function signalChangeReferrerAddress(
        address newAddress
    ) external {
        if (msg.sender != referrer) revert NotRecipient();
        _signal(ACTION_CHANGE_REFERRER, keccak256(abi.encode(newAddress)));
    }

    /// @notice Execute referrer address change. Permissionless after delay.
    /// @param newAddress New referrer address (must match signaled value)
    function executeChangeReferrerAddress(
        address newAddress
    ) external {
        _execute(ACTION_CHANGE_REFERRER, keccak256(abi.encode(newAddress)));
        if (newAddress == address(0)) revert ZeroAddress();
        emit ReferrerAddressChanged(referrer, newAddress);
        referrer = newAddress;
    }

    /// @notice Cancel pending referrer address change. Only current recipient.
    function cancelChangeReferrerAddress() external {
        if (msg.sender != referrer) revert NotRecipient();
        _cancel(ACTION_CHANGE_REFERRER);
    }

    // ============ Fee Collector Migration ============

    /// @notice Update the fee collector address. Only callable by the current fee collector.
    /// @dev Used during collector migration. Revokes old approval, grants new one.
    ///      Also updates tax exemption on the BoardwalkToken.
    /// @param newFeeCollector Address of the new BoardwalkFeeCollector
    function setFeeCollector(
        address newFeeCollector
    ) external {
        if (msg.sender != feeCollector) revert OnlyFeeCollector();
        if (newFeeCollector == address(0)) revert ZeroAddress();
        // Update tax exemption
        IBoardwalkToken(token).updateExempt(feeCollector, false);
        IBoardwalkToken(token).updateExempt(newFeeCollector, true);
        IERC20(token).approve(feeCollector, 0);
        emit FeeCollectorChanged(feeCollector, newFeeCollector);
        feeCollector = newFeeCollector;
        IERC20(token).approve(newFeeCollector, type(uint256).max);
    }

    function _authAdmin(
        bytes32
    ) internal pure override {
        revert NotAuthorized();
    }

    // ============ Internal Functions ============

    function _forwardLpFees(
        uint256 amount
    ) internal {
        try ILPStaking(lpStaking).notifyFees(amount) {}
        catch {
            pendingLpFees += amount;
            emit FeeForwardFailed("LPStaking", amount);
        }
    }

    function _forwardBoardwalkFees(
        uint256 amount
    ) internal {
        try IBoardwalkFeeCollector(feeCollector).receiveFees(token, amount) {}
        catch {
            pendingBoardwalkFees += amount;
            emit FeeForwardFailed("FeeCollector", amount);
        }
    }

    /// @dev Shared validation for referrer and integrator claims
    function _validateThirdPartyClaim(
        uint256 accrued,
        uint256 alreadyClaimed
    ) internal pure returns (uint256 amount) {
        amount = accrued - alreadyClaimed;
        if (amount == 0) revert NothingToClaimYet();
    }

    /// @dev Accrue issuer fees split among recipients by their configured splits.
    ///      Last recipient gets remainder to avoid rounding dust being locked.
    function _accrueIssuerFees(
        uint256 totalIssuerShare
    ) internal {
        uint256 distributed;
        uint256 len = issuerRecipients.length;
        for (uint256 i = 0; i < len - 1;) {
            uint256 recipientShare = totalIssuerShare * issuerSplits[i] / BPS_DENOMINATOR;
            issuerClaimStates[i].totalAccrued += recipientShare;
            distributed += recipientShare;
            unchecked {
                ++i;
            }
        }
        // Last recipient gets the remainder (avoids dust)
        issuerClaimStates[len - 1].totalAccrued += totalIssuerShare - distributed;
    }

    /// @dev Update claim state after a successful claim
    function _updateClaimState(
        uint256 recipientIdx,
        uint256 amount
    ) internal {
        ClaimState storage state = issuerClaimStates[recipientIdx];

        if (block.timestamp >= state.lastClaimTime + 1 days) {
            // New period
            state.lastClaimTime = SafeCast.toUint64(block.timestamp);
            state.claimedInCurrentPeriod = amount;
        } else {
            // Same period
            state.claimedInCurrentPeriod += amount;
        }

        state.totalClaimed += amount;
    }

    /// @dev Return the minimum of two values
    function _min(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ============ View Functions ============

    function issuerRecipientCount() external view returns (uint256) {
        return issuerRecipients.length;
    }
}

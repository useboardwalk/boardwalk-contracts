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
import {IIntegratorFeeCollector} from "../interfaces/IIntegratorFeeCollector.sol";

/// @title FeeDistributor
/// @notice Per-launch clone. `onTaxReceived` splits the tax across LP / boardwalk / issuer /
///         referrer / integrator buckets. LP, boardwalk, and integrator fees are forwarded via
///         `try/catch` so a downstream revert never bricks the transfer. Issuer and referrer fees
///         accrue for pull-based claims.
/// @dev    Inherits Timelocked but `_authAdmin` reverts, disabling the generic `signalAction`
///         path. Only the typed per-recipient flows mutate state.
contract FeeDistributor is Timelocked, Initializable {
    using SafeERC20 for IERC20;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    bytes32 public constant ACTION_CHANGE_ISSUER = keccak256("CHANGE_ISSUER");
    bytes32 public constant ACTION_CHANGE_REFERRER = keccak256("CHANGE_REFERRER");

    address public token;
    address public lpStaking;
    address public feeCollector;
    address public integratorCollector;
    address public router;
    address public raiseToken;

    uint256 public issuerBps;
    uint256 public boardwalkBps;
    uint256 public lpIncentiveBps;
    uint256 public referrerBps;
    uint256 public integratorBps;
    uint256 public totalFeeBps;

    address[] public issuerRecipients;
    uint256[] public issuerSplits;

    address public referrer;

    struct ClaimState {
        uint256 totalAccrued;
        uint256 totalClaimed;
        uint256 claimedInCurrentPeriod;
        uint64 lastClaimTime;
    }

    mapping(uint256 => ClaimState) public issuerClaimStates;

    uint256 public referrerAccrued;
    uint256 public referrerClaimed;

    /// @notice Fees from downstream forwards that reverted; flushable via `retryPendingFees`.
    uint256 public pendingLpFees;
    uint256 public pendingBoardwalkFees;
    uint256 public pendingIntegratorFees;

    struct InitParams {
        address token;
        address lpStaking;
        address feeCollector;
        address integratorCollector;
        address router;
        address raiseToken;
        address[] issuerRecipients;
        uint256[] issuerSplits;
        address referrer;
        uint256 issuerBps;
        uint256 boardwalkBps;
        uint256 lpIncentiveBps;
        uint256 referrerBps;
        uint256 integratorBps;
    }

    error OnlyToken();
    error NotRecipient();
    error NothingToClaimYet();
    error ZeroAddress();
    error InvalidFeeBps();
    error InvalidSplitsSum();
    error ArrayLengthMismatch();
    error OnlyFeeCollector();
    error NotAuthorized();
    error DuplicateRoleAddress();

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
    event FeeForwardFailed(string target, uint256 amount);
    event FeeCollectorChanged(address oldCollector, address newCollector);
    event IssuerAddressChanged(uint256 indexed recipientIdx, address oldAddress, address newAddress);
    event ReferrerAddressChanged(address oldAddress, address newAddress);

    constructor() {
        _disableInitializers();
    }

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

        uint256 splitsSum;
        for (uint256 i = 0; i < p.issuerSplits.length;) {
            splitsSum += p.issuerSplits[i];
            if (p.issuerRecipients[i] == address(0)) revert ZeroAddress();
            unchecked {
                ++i;
            }
        }
        if (splitsSum != BPS_DENOMINATOR) revert InvalidSplitsSum();

        uint256 _totalFeeBps = p.issuerBps + p.boardwalkBps + p.lpIncentiveBps + p.referrerBps + p.integratorBps;
        if (_totalFeeBps == 0) revert InvalidFeeBps();

        token = p.token;
        lpStaking = p.lpStaking;
        feeCollector = p.feeCollector;
        integratorCollector = p.integratorCollector;
        router = p.router;
        raiseToken = p.raiseToken;

        issuerBps = p.issuerBps;
        boardwalkBps = p.boardwalkBps;
        lpIncentiveBps = p.lpIncentiveBps;
        referrerBps = p.referrerBps;
        integratorBps = p.integratorBps;
        totalFeeBps = _totalFeeBps;

        for (uint256 i = 0; i < p.issuerRecipients.length;) {
            issuerRecipients.push(p.issuerRecipients[i]);
            issuerSplits.push(p.issuerSplits[i]);
            unchecked {
                ++i;
            }
        }

        referrer = p.referrer;

        // LPStaking pulls via notifyFees; FeeCollector and IntegratorFeeCollector pull via receiveFees;
        // Router pulls during issuer claim.
        IERC20(p.token).approve(p.lpStaking, type(uint256).max);
        IERC20(p.token).approve(p.feeCollector, type(uint256).max);
        IERC20(p.token).approve(p.router, type(uint256).max);
        if (p.integratorBps > 0) {
            IERC20(p.token).approve(p.integratorCollector, type(uint256).max);
        }
    }

    /// @notice Called by BoardwalkToken on every taxed transfer. Splits by frozen BPS. LP /
    ///         boardwalk / integrator forwards are wrapped in try/catch so a bad downstream cannot
    ///         revert the transfer; failed amounts accumulate and can be flushed
    ///         later via the permissionless `retryPendingFees`.
    function onTaxReceived(
        uint256 amount
    ) external {
        if (msg.sender != token) revert OnlyToken();

        uint256 _totalFeeBps = totalFeeBps;
        uint256 lpShare = amount * lpIncentiveBps / _totalFeeBps;
        uint256 boardwalkShare = amount * boardwalkBps / _totalFeeBps;
        uint256 referrerShare = (referrer != address(0)) ? amount * referrerBps / _totalFeeBps : 0;
        uint256 integratorShare = (integratorBps > 0) ? amount * integratorBps / _totalFeeBps : 0;
        uint256 issuerShare = amount - lpShare - boardwalkShare - referrerShare - integratorShare;

        if (lpShare > 0) _forwardLpFees(lpShare);
        if (boardwalkShare > 0) _forwardBoardwalkFees(boardwalkShare);
        if (integratorShare > 0) _forwardIntegratorFees(integratorShare);

        if (issuerShare > 0) {
            _accrueIssuerFees(issuerShare);
        }

        if (referrerShare > 0) {
            referrerAccrued += referrerShare;
        }

        emit TaxReceived(amount, lpShare, boardwalkShare, issuerShare, referrerShare, integratorShare);
    }

    /// @notice Flush any fees that accumulated when a forward reverted. Permissionless.
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
        uint256 intAmount = pendingIntegratorFees;
        if (intAmount > 0) {
            pendingIntegratorFees = 0;
            _forwardIntegratorFees(intAmount);
        }
    }

    /// @notice Issuer recipient claims accrued fees swapped to raise token. Rate limit: 10% of
    ///         `totalAccrued` per recipient per 24h.
    function claimAsRaiseToken(
        uint256 recipientIdx,
        uint256 minRaiseTokenOut,
        uint256 deadline
    ) external {
        if (msg.sender != issuerRecipients[recipientIdx]) revert NotRecipient();

        uint256 tokenAmount = claimableAmount(recipientIdx);
        if (tokenAmount == 0) revert NothingToClaimYet();

        _updateClaimState(recipientIdx, tokenAmount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = raiseToken;

        uint256[] memory amounts =
            IDEXRouter(router).swapExactTokensForTokens(tokenAmount, minRaiseTokenOut, path, msg.sender, deadline);

        emit IssuerClaimed(recipientIdx, msg.sender, tokenAmount, amounts[1]);
    }

    /// @notice Claimable issuer fee amount respecting the 10%/24h rate limit and dust escape.
    function claimableAmount(
        uint256 recipientIdx
    ) public view returns (uint256) {
        ClaimState memory state = issuerClaimStates[recipientIdx];
        if (state.totalAccrued == 0) return 0;

        uint256 unclaimed = state.totalAccrued - state.totalClaimed;
        if (unclaimed == 0) return 0;

        uint256 maxClaimable = state.totalAccrued / 10;

        // Dust escape: when 10% rounds to zero, bypass the rate limit to unstick small balances.
        if (maxClaimable == 0) return unclaimed;

        if (block.timestamp >= state.lastClaimTime + 1 days) {
            return _min(maxClaimable, unclaimed);
        }

        if (state.claimedInCurrentPeriod >= maxClaimable) return 0;
        uint256 remainingInPeriod = maxClaimable - state.claimedInCurrentPeriod;
        return _min(remainingInPeriod, unclaimed);
    }

    function claimReferrerFees() external {
        if (msg.sender != referrer) revert NotRecipient();
        uint256 amount = _validateThirdPartyClaim(referrerAccrued, referrerClaimed);
        referrerClaimed += amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit ReferrerClaimed(msg.sender, amount);
    }

    function signalChangeIssuerAddress(
        uint256 recipientIdx,
        address newAddress
    ) external {
        if (msg.sender != issuerRecipients[recipientIdx]) revert NotRecipient();
        bytes32 action = keccak256(abi.encode(ACTION_CHANGE_ISSUER, recipientIdx));
        _signal(action, keccak256(abi.encode(newAddress)));
    }

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

    function cancelChangeIssuerAddress(
        uint256 recipientIdx
    ) external {
        if (msg.sender != issuerRecipients[recipientIdx]) revert NotRecipient();
        bytes32 action = keccak256(abi.encode(ACTION_CHANGE_ISSUER, recipientIdx));
        _cancel(action);
    }

    function signalChangeReferrerAddress(
        address newAddress
    ) external {
        if (msg.sender != referrer) revert NotRecipient();
        _signal(ACTION_CHANGE_REFERRER, keccak256(abi.encode(newAddress)));
    }

    function executeChangeReferrerAddress(
        address newAddress
    ) external {
        _execute(ACTION_CHANGE_REFERRER, keccak256(abi.encode(newAddress)));
        if (newAddress == address(0)) revert ZeroAddress();
        emit ReferrerAddressChanged(referrer, newAddress);
        referrer = newAddress;
    }

    function cancelChangeReferrerAddress() external {
        if (msg.sender != referrer) revert NotRecipient();
        _cancel(ACTION_CHANGE_REFERRER);
    }

    /// @notice Collector migration hook. Atomically rotates token exemption and approvals to the
    ///         new collector. Only the current collector can call.
    function setFeeCollector(
        address newFeeCollector
    ) external {
        if (msg.sender != feeCollector) revert OnlyFeeCollector();
        if (newFeeCollector == address(0)) revert ZeroAddress();
        if (IBoardwalkToken(token).isExempt(newFeeCollector)) revert DuplicateRoleAddress();
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

    function _forwardIntegratorFees(
        uint256 amount
    ) internal {
        try IIntegratorFeeCollector(integratorCollector).receiveFees(token, amount) {}
        catch {
            pendingIntegratorFees += amount;
            emit FeeForwardFailed("Integrator", amount);
        }
    }

    function _validateThirdPartyClaim(
        uint256 accrued,
        uint256 alreadyClaimed
    ) internal pure returns (uint256 amount) {
        amount = accrued - alreadyClaimed;
        if (amount == 0) revert NothingToClaimYet();
    }

    /// @dev Last recipient receives the remainder so BPS rounding never leaves dust behind.
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
        issuerClaimStates[len - 1].totalAccrued += totalIssuerShare - distributed;
    }

    function _updateClaimState(
        uint256 recipientIdx,
        uint256 amount
    ) internal {
        ClaimState storage state = issuerClaimStates[recipientIdx];

        if (block.timestamp >= state.lastClaimTime + 1 days) {
            state.lastClaimTime = SafeCast.toUint64(block.timestamp);
            state.claimedInCurrentPeriod = amount;
        } else {
            state.claimedInCurrentPeriod += amount;
        }

        state.totalClaimed += amount;
    }

    function _min(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function issuerRecipientCount() external view returns (uint256) {
        return issuerRecipients.length;
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Timelocked} from "../base/Timelocked.sol";
import {IBoardwalkToken} from "../interfaces/IBoardwalkToken.sol";
import {ILaunchFactory} from "../interfaces/ILaunchFactory.sol";
import {IDEXRouter} from "../interfaces/IDEXRouter.sol";

/// @title IntegratorFeeCollector
/// @notice Per-chain singleton aggregator for the integrator share of every launch's tax. Holds
///         frozen `integrators[]` + `integratorSplits[]` set at construction; `receiveFees`
///         allocates inbound buckets per slot. Each slot rate-limits claims to 25%/24h per token
///         and swaps to the raise token via the standard router.
/// @dev    Tax-exempt on every launched token (added by LaunchFactory). Inherits Timelocked but
///         `_authAdmin` reverts; only typed slot rotation mutates state.
contract IntegratorFeeCollector is Ownable2Step, Timelocked {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant CLAIM_RATE_DIVISOR = 4; // 25%/24h per (slot, token)
    uint256 public constant ROTATION_DELAY = 14 days;
    uint256 public constant MAX_INTEGRATOR_SLOTS = 5;

    bytes32 public constant ACTION_CHANGE_ADDRESS = keccak256("CHANGE_ADDRESS");

    address public immutable RAISE_TOKEN;
    address public immutable ROUTER;

    address public factory;

    address[] public integrators;
    uint256[] public integratorSplits;

    /// @dev `0` = not an integrator; `slot+1` = registered at slot.
    mapping(address => uint256) private _slotPlusOne;

    struct ClaimState {
        uint256 totalAccrued;
        uint256 totalClaimed;
        uint256 claimedInCurrentPeriod;
        uint64 lastClaimTime;
    }

    mapping(uint256 => mapping(address => ClaimState)) public claimStates;

    mapping(uint256 => EnumerableSet.AddressSet) private _trackedTokens;

    error NotIntegrator();
    error NotAuthorized();
    error InvalidSlot();
    error OnlySelf();
    error NothingToClaimYet();
    error ZeroAddress();
    error ArrayLengthMismatch();
    error EmptyArray();
    error InvalidSplitsSum();
    error DuplicateIntegrator();
    error ZeroSplit();
    error InvalidIntegrator();
    error TooManySlots();
    error UnknownToken();
    error UnknownSender();
    error FactoryAlreadySet();
    error FactoryMismatch();
    error NotAContract();
    error DuplicateAddress();
    error InvalidSlippageBps();
    error QuoteFailed();

    event FactorySet(address indexed factory);
    event FeesReceived(address indexed token, address indexed feeDistributor, uint256 amount);
    event FeesClaimed(
        uint256 indexed slotIdx, address indexed token, address indexed to, uint256 amountIn, uint256 raiseTokenOut
    );
    event ClaimFailed(uint256 indexed slotIdx, address indexed token);
    event AddressChanged(uint256 indexed slotIdx, address oldAddress, address newAddress);

    constructor(
        address _owner,
        address _raiseToken,
        address _router,
        address[] memory _integrators,
        uint256[] memory _integratorSplits
    ) Ownable(_owner) {
        if (_raiseToken == address(0)) revert ZeroAddress();
        if (_router == address(0)) revert ZeroAddress();

        uint256 len = _integrators.length;
        if (len == 0) revert EmptyArray();
        if (len > MAX_INTEGRATOR_SLOTS) revert TooManySlots();
        if (_integratorSplits.length != len) revert ArrayLengthMismatch();

        RAISE_TOKEN = _raiseToken;
        ROUTER = _router;

        uint256 splitsSum;
        for (uint256 i = 0; i < len;) {
            address addr = _integrators[i];
            uint256 split = _integratorSplits[i];

            _validateIntegratorAddress(addr);
            if (split == 0) revert ZeroSplit();
            if (_slotPlusOne[addr] != 0) revert DuplicateIntegrator();

            integrators.push(addr);
            integratorSplits.push(split);
            _slotPlusOne[addr] = i + 1;
            splitsSum += split;

            unchecked {
                ++i;
            }
        }

        if (splitsSum != BPS_DENOMINATOR) revert InvalidSplitsSum();
    }

    /// @notice Binds this collector to the LaunchFactory deployed against it.
    function setFactory(
        address _factory
    ) external onlyOwner {
        if (_factory == address(0)) revert ZeroAddress();
        if (factory != address(0)) revert FactoryAlreadySet();
        if (_factory.code.length == 0) revert NotAContract();
        if (ILaunchFactory(_factory).INTEGRATOR_COLLECTOR() != address(this)) revert FactoryMismatch();
        factory = _factory;
        emit FactorySet(_factory);
    }

    /// @notice Called by a launch's FeeDistributor to deposit the integrator bucket. Allocates
    ///         across slots by splits; last slot absorbs rounding dust.
    function receiveFees(
        address token,
        uint256 totalAmount
    ) external {
        address _factory = factory;
        if (_factory == address(0)) revert UnknownSender();
        if (!ILaunchFactory(_factory).isLaunchToken(token)) revert UnknownToken();
        if (IBoardwalkToken(token).feeDistributor() != msg.sender) revert UnknownSender();
        if (totalAmount == 0) return;

        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);
        _allocate(token, totalAmount);

        emit FeesReceived(token, msg.sender, totalAmount);
    }

    /// @notice Claim one token's accrued fees swapped to the raise token.
    /// @param token The launch token to claim accrued fees for.
    /// @param minOut Minimum output amount (get via `quote`).
    /// @param deadline Swap deadline.
    function claim(
        address token,
        uint256 minOut,
        uint256 deadline
    ) external {
        _attemptClaim(_slotOf(msg.sender), token, minOut, deadline, true);
    }

    /// @notice Claim multiple tokens in one tx.
    /// @dev    Each per-token attempt is isolated so a swap revert emits `ClaimFailed`;
    ///         leaves rate-limit untouched; tokens with nothing claimable are skipped.
    /// @param tokens The launch tokens to claim accrued fees for.
    /// @param minAmountsOut Minimum output amounts (get via `quoteBatch`).
    /// @param deadline Swap deadline.
    function claimBatch(
        address[] calldata tokens,
        uint256[] calldata minAmountsOut,
        uint256 deadline
    ) external {
        uint256 len = tokens.length;
        if (len == 0) revert EmptyArray();
        if (minAmountsOut.length != len) revert ArrayLengthMismatch();

        uint256 slotIdx = _slotOf(msg.sender);

        for (uint256 i = 0; i < len;) {
            try this._claimOneToken(slotIdx, tokens[i], minAmountsOut[i], deadline) {}
            catch {
                emit ClaimFailed(slotIdx, tokens[i]);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev External-but-self-only so `claimBatch` can `try/catch` per-token reverts.
    ///      Slot bounds are guaranteed by `claimBatch`'s `_slotOf(msg.sender)`.
    function _claimOneToken(
        uint256 slotIdx,
        address token,
        uint256 minOut,
        uint256 deadline
    ) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _attemptClaim(slotIdx, token, minOut, deadline, false);
    }

    /// @notice Signal a rotation of the caller's slot to a new address. 14-day delay.
    function signalChangeAddress(
        address newAddress
    ) external {
        uint256 slotIdx = _slotOf(msg.sender);
        bytes32 action = keccak256(abi.encode(ACTION_CHANGE_ADDRESS, slotIdx));
        _signal(action, keccak256(abi.encode(newAddress)), ROTATION_DELAY);
    }

    function executeChangeAddress(
        uint256 slotIdx,
        address newAddress
    ) external {
        if (slotIdx >= integrators.length) revert InvalidSlot();
        bytes32 action = keccak256(abi.encode(ACTION_CHANGE_ADDRESS, slotIdx));
        _execute(action, keccak256(abi.encode(newAddress)));

        _validateIntegratorAddress(newAddress);
        if (_slotPlusOne[newAddress] != 0) revert DuplicateAddress();

        address oldAddress = integrators[slotIdx];
        delete _slotPlusOne[oldAddress];
        _slotPlusOne[newAddress] = slotIdx + 1;
        integrators[slotIdx] = newAddress;

        emit AddressChanged(slotIdx, oldAddress, newAddress);
    }

    /// @notice Cancel a pending rotation. Caller must be the current address for the slot.
    function cancelChangeAddress() external {
        uint256 slotIdx = _slotOf(msg.sender);
        _cancel(keccak256(abi.encode(ACTION_CHANGE_ADDRESS, slotIdx)));
    }

    function slotCount() external view returns (uint256) {
        return integrators.length;
    }

    function slotOf(
        address integrator
    ) external view returns (uint256) {
        return _slotOf(integrator);
    }

    function isIntegrator(
        address account
    ) external view returns (bool) {
        return _slotPlusOne[account] != 0;
    }

    /// @notice Claimable amount of `token` for `integrator`, respecting the 25%/24h rate limit.
    function claimableAmount(
        address integrator,
        address token
    ) external view returns (uint256) {
        return _claimableBySlot(_slotOf(integrator), token);
    }

    function trackedTokenCount(
        address integrator
    ) external view returns (uint256) {
        return _trackedTokens[_slotOf(integrator)].length();
    }

    function trackedTokenAt(
        address integrator,
        uint256 i
    ) external view returns (address) {
        return _trackedTokens[_slotOf(integrator)].at(i);
    }

    function isTracked(
        address integrator,
        address token
    ) external view returns (bool) {
        return _trackedTokens[_slotOf(integrator)].contains(token);
    }

    /// @notice Full set of tokens with non-zero accrual for `integrator`.
    function trackedTokens(
        address integrator
    ) external view returns (address[] memory) {
        return _trackedTokens[_slotOf(integrator)].values();
    }

    /// @notice Returns claimable amount and slippage-adjusted minOut. Use with `claim`.
    /// @dev    Returns `(0, 0)` when nothing claimable; reverts
    ///         `QuoteFailed` if the router cannot quote.
    /// @return amountIn The claimable amount of `token`.
    /// @return minOut The slippage-adjusted minOut.
    function quote(
        address integrator,
        address token,
        uint256 slippageBps
    ) external view returns (uint256 amountIn, uint256 minOut) {
        if (slippageBps > BPS_DENOMINATOR) revert InvalidSlippageBps();
        amountIn = _claimableBySlot(_slotOf(integrator), token);
        if (amountIn == 0) return (0, 0);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = RAISE_TOKEN;

        try IDEXRouter(ROUTER).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            minOut = amounts[1] * (BPS_DENOMINATOR - slippageBps) / BPS_DENOMINATOR;
        } catch {
            revert QuoteFailed();
        }
    }

    /// @notice Batched version of `quote`. Returns the subset of `tokens` that are claimable right
    ///         now plus amounts and slippage-adjusted minOuts. Use with `claimBatch`.
    /// @dev    Tokens with nothing claimable or a router quote failure are silently omitted from
    ///         the result (rather than reverting like `quote`), so the returned arrays are always
    ///         a directly-claimable subset.
    /// @return tokens_ The subset of `tokens` that are claimable right now.
    /// @return amountsIn The amounts of each claimable token.
    /// @return minAmountsOut The slippage-adjusted minOuts for each claimable token.
    function quoteBatch(
        address integrator,
        address[] calldata tokens,
        uint256 slippageBps
    ) external view returns (address[] memory tokens_, uint256[] memory amountsIn, uint256[] memory minAmountsOut) {
        if (slippageBps > BPS_DENOMINATOR) revert InvalidSlippageBps();
        uint256 slotIdx = _slotOf(integrator);
        uint256 inputLen = tokens.length;

        address[] memory tempTokens = new address[](inputLen);
        uint256[] memory tempAmounts = new uint256[](inputLen);
        uint256[] memory tempMins = new uint256[](inputLen);

        address[] memory path = new address[](2);
        path[1] = RAISE_TOKEN;

        uint256 outLen;
        for (uint256 i = 0; i < inputLen;) {
            uint256 amountIn = _claimableBySlot(slotIdx, tokens[i]);
            if (amountIn != 0) {
                path[0] = tokens[i];
                try IDEXRouter(ROUTER).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
                    tempTokens[outLen] = tokens[i];
                    tempAmounts[outLen] = amountIn;
                    tempMins[outLen] = amounts[1] * (BPS_DENOMINATOR - slippageBps) / BPS_DENOMINATOR;
                    unchecked {
                        ++outLen;
                    }
                } catch {}
            }
            unchecked {
                ++i;
            }
        }

        tokens_ = new address[](outLen);
        amountsIn = new uint256[](outLen);
        minAmountsOut = new uint256[](outLen);
        for (uint256 i = 0; i < outLen;) {
            tokens_[i] = tempTokens[i];
            amountsIn[i] = tempAmounts[i];
            minAmountsOut[i] = tempMins[i];
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Disables the generic Timelocked admin path; only typed slot rotation mutates state.
    function _authAdmin(
        bytes32
    ) internal pure override {
        revert NotAuthorized();
    }

    function _slotOf(
        address addr
    ) internal view returns (uint256) {
        uint256 s = _slotPlusOne[addr];
        if (s == 0) revert NotIntegrator();
        return s - 1;
    }

    /// @dev Shared address-eligibility gate for both constructor and slot rotation.
    function _validateIntegratorAddress(
        address addr
    ) internal view {
        if (addr == address(0)) revert ZeroAddress();
        if (addr == address(this) || addr == ROUTER || addr == RAISE_TOKEN) revert InvalidIntegrator();
    }

    /// @dev Slot-keyed sibling of the public `claimableAmount`.
    function _claimableBySlot(
        uint256 slotIdx,
        address token
    ) internal view returns (uint256) {
        ClaimState memory state = claimStates[slotIdx][token];
        if (state.totalAccrued == 0) return 0;

        uint256 unclaimed = state.totalAccrued - state.totalClaimed;
        if (unclaimed == 0) return 0;

        uint256 maxClaimable = unclaimed / CLAIM_RATE_DIVISOR;

        // Dust escape: when 25% of unclaimed rounds to zero, return the full residue.
        if (maxClaimable == 0) return unclaimed;

        if (block.timestamp >= state.lastClaimTime + 1 days) {
            return _min(maxClaimable, unclaimed);
        }

        if (state.claimedInCurrentPeriod >= maxClaimable) return 0;
        uint256 remainingInPeriod = maxClaimable - state.claimedInCurrentPeriod;
        return _min(remainingInPeriod, unclaimed);
    }

    /// @dev Last slot absorbs rounding dust so the entire `totalAmount` is allocated.
    function _allocate(
        address token,
        uint256 totalAmount
    ) internal {
        uint256 len = integrators.length;
        uint256 distributed;

        for (uint256 i = 0; i < len - 1;) {
            uint256 share = totalAmount * integratorSplits[i] / BPS_DENOMINATOR;
            if (share > 0) {
                claimStates[i][token].totalAccrued += share;
                _trackedTokens[i].add(token);
            }
            distributed += share;
            unchecked {
                ++i;
            }
        }

        uint256 lastShare = totalAmount - distributed;
        if (lastShare > 0) {
            claimStates[len - 1][token].totalAccrued += lastShare;
            _trackedTokens[len - 1].add(token);
        }
    }

    /// @dev Shared per-token claim path. `revertOnZero=true` for `claim` (singular fails loudly);
    ///      `false` for the batch path so empty buckets are skipped silently.
    function _attemptClaim(
        uint256 slotIdx,
        address token,
        uint256 minOut,
        uint256 deadline,
        bool revertOnZero
    ) internal {
        uint256 amountIn = _claimableBySlot(slotIdx, token);
        if (amountIn == 0) {
            if (revertOnZero) revert NothingToClaimYet();
            return;
        }
        _swapAndUpdate(slotIdx, token, amountIn, minOut, deadline);
    }

    /// @dev A swap revert rolls back the whole tx for `claim` and the per-token try/catch
    ///      for `claimBatch`.
    function _swapAndUpdate(
        uint256 slotIdx,
        address token,
        uint256 amountIn,
        uint256 minOut,
        uint256 deadline
    ) internal {
        ClaimState storage state = claimStates[slotIdx][token];
        if (block.timestamp >= state.lastClaimTime + 1 days) {
            state.lastClaimTime = SafeCast.toUint64(block.timestamp);
            state.claimedInCurrentPeriod = amountIn;
        } else {
            state.claimedInCurrentPeriod += amountIn;
        }
        state.totalClaimed += amountIn;

        // Prune from tracked set on full exhaustion; next receiveFees re-adds.
        if (state.totalClaimed == state.totalAccrued) {
            _trackedTokens[slotIdx].remove(token);
        }

        if (IERC20(token).allowance(address(this), ROUTER) < amountIn) {
            IERC20(token).forceApprove(ROUTER, type(uint256).max);
        }

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = RAISE_TOKEN;

        address to = integrators[slotIdx];
        uint256[] memory amounts = IDEXRouter(ROUTER).swapExactTokensForTokens(amountIn, minOut, path, to, deadline);

        emit FeesClaimed(slotIdx, token, to, amountIn, amounts[1]);
    }

    function _min(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

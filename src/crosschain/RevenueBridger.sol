// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Timelocked} from "../base/Timelocked.sol";
import {ILiFi} from "../interfaces/ILiFi.sol";

/// @title RevenueBridger
/// @notice Bridger deployed to each non-Base chain. Holds the chain's raise token and
///         forwards keeper-built LiFi route calldata to the per-chain LiFi Diamond,
///         pinned to deliver to the `BaseRevenueSwapper` on Base.
contract RevenueBridger is Ownable2Step, Timelocked, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public immutable DIAMOND; // LiFi Diamond
    address public immutable RAISE_TOKEN;
    address public immutable BASE_DESTINATION; // BaseRevenueSwapper on Base
    address public immutable BASE_WETH;
    /// @dev True for composed (source-swap) lanes, false for pure Across V4 lanes.
    bool public immutable HAS_SOURCE_SWAPS;
    /// @dev Max tolerated relayer-fee spread on the Across `outputAmount` floor.
    uint256 public immutable MAX_FEE_BPS;

    uint256 public constant BASE_CHAIN_ID = 8453;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    bytes32 public constant ACTION_SET_KEEPER = keccak256("REVENUE_BRIDGER_SET_KEEPER");
    bytes32 public constant ACTION_SET_SELECTOR = keccak256("REVENUE_BRIDGER_SET_SELECTOR");
    bytes32 public constant ACTION_RESCUE = keccak256("REVENUE_BRIDGER_RESCUE");

    /// @dev Bridge keeper
    address public keeper;
    /// @dev Allowlisted LiFi facet selectors; one per lane.
    mapping(bytes4 => bool) public allowedSelectors;

    error NotKeeper();
    error NotAuthorized();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidConfig();
    error CalldataTooShort();
    error SelectorNotAllowed(bytes4 selector);
    error InvalidReceiver();
    error InvalidDestinationChain();
    error DestinationCallNotAllowed();
    error InvalidSendingAsset();
    error InvalidMinAmount();
    error InvalidRefundAddress();
    error InvalidReceivingAsset();
    error InsufficientOutputAmount();
    error InvalidReceiverAddress();
    error DepositSumMismatch();
    error BridgeCallFailed();
    error BalanceDeltaExceeded();
    error InvalidSourceSwaps();
    error NativeRefundFailed();
    error RescueFailed();

    event BridgedToBase(bytes4 indexed selector, uint256 amount, uint256 balanceDelta, uint256 nativeFee);
    event KeeperRevoked(address indexed previousKeeper);
    event KeeperUpdated(address indexed newKeeper);
    event SelectorSet(bytes4 indexed selector, bool allowed);
    event AssetRescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        address _owner,
        address _diamond,
        address _raiseToken,
        address _baseDestination,
        address _baseWeth,
        address _keeper,
        bool _hasSourceSwaps,
        uint256 _maxFeeBps,
        bytes4[] memory _initialSelectors
    ) Ownable(_owner) {
        if (
            _diamond == address(0) || _raiseToken == address(0) || _baseDestination == address(0)
                || _baseWeth == address(0) || _keeper == address(0)
        ) revert ZeroAddress();
        if (_maxFeeBps >= BPS_DENOMINATOR) revert InvalidConfig();

        DIAMOND = _diamond;
        RAISE_TOKEN = _raiseToken;
        BASE_DESTINATION = _baseDestination;
        BASE_WETH = _baseWeth;
        keeper = _keeper;
        HAS_SOURCE_SWAPS = _hasSourceSwaps;
        MAX_FEE_BPS = _maxFeeBps;

        for (uint256 i = 0; i < _initialSelectors.length;) {
            allowedSelectors[_initialSelectors[i]] = true;
            emit SelectorSet(_initialSelectors[i], true);
            unchecked {
                ++i;
            }
        }
    }

    receive() external payable {}

    /// @notice Bridge `amount` of the raise token to Base via the keeper-supplied LiFi route.
    /// @param amount The raise token amount to deposit into the route.
    /// @param lifiCalldata The keeper-built LiFi Diamond calldata (selector + `BridgeData` + facet data).
    function bridgeToBase(
        uint256 amount,
        bytes calldata lifiCalldata
    ) external payable nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();
        if (amount == 0) revert ZeroAmount();
        if (lifiCalldata.length < 4) revert CalldataTooShort();

        bytes4 selector = bytes4(lifiCalldata);
        if (!allowedSelectors[selector]) revert SelectorNotAllowed(selector);

        _validatePinning(amount, lifiCalldata);

        address raiseToken = RAISE_TOKEN;
        address diamond = DIAMOND;
        uint256 balanceBefore = IERC20(raiseToken).balanceOf(address(this));
        // Pre-existing native is never forwarded or refunded here, only rescued.
        uint256 nativeBefore = address(this).balance - msg.value;

        IERC20(raiseToken).forceApprove(diamond, amount);
        (bool ok,) = diamond.call{value: msg.value}(lifiCalldata);
        if (!ok) revert BridgeCallFailed();
        IERC20(raiseToken).forceApprove(diamond, 0);

        uint256 balanceAfter = IERC20(raiseToken).balanceOf(address(this));
        // A balance gain is anomalous and rejected; `<= amount` (not `==`) tolerates partial-pull/refund routes.
        uint256 delta = balanceBefore >= balanceAfter ? balanceBefore - balanceAfter : type(uint256).max;
        if (delta > amount) revert BalanceDeltaExceeded();

        // Refund unconsumed native to the keeper.
        uint256 refund = address(this).balance > nativeBefore ? address(this).balance - nativeBefore : 0;
        if (refund > 0) {
            (bool refunded,) = msg.sender.call{value: refund}("");
            if (!refunded) revert NativeRefundFailed();
        }

        emit BridgedToBase(selector, amount, delta, msg.value > refund ? msg.value - refund : 0);
    }

    /// @dev Decodes the keeper calldata and pins the fields the lane's facet consumes.
    function _validatePinning(
        uint256 amount,
        bytes calldata lifiCalldata
    ) internal view {
        // Every facet takes `ILiFi.BridgeData` first; decoding it (or a prefix tuple) from longer calldata is sound.
        ILiFi.BridgeData memory bridgeData = abi.decode(lifiCalldata[4:], (ILiFi.BridgeData));

        if (bridgeData.receiver != BASE_DESTINATION) revert InvalidReceiver();
        if (bridgeData.destinationChainId != BASE_CHAIN_ID) revert InvalidDestinationChain();
        if (bridgeData.hasDestinationCall) revert DestinationCallNotAllowed();
        // Reject a calldata shape that doesn't match the lane's frozen config.
        if (bridgeData.hasSourceSwaps != HAS_SOURCE_SWAPS) revert InvalidSourceSwaps();

        if (!HAS_SOURCE_SWAPS) {
            // Pure Across V4 (ETH/Ink): the facet deposits `BridgeData.sendingAssetId`/`minAmount`, so pin them.
            if (bridgeData.sendingAssetId != RAISE_TOKEN) revert InvalidSendingAsset();
            if (bridgeData.minAmount != amount) revert InvalidMinAmount();

            (, ILiFi.AcrossV4Data memory acrossData) =
                abi.decode(lifiCalldata[4:], (ILiFi.BridgeData, ILiFi.AcrossV4Data));

            // refundAddress is the depositor and the recipient of an unfilled-deposit refund; pin it here so
            // a forced expiry returns funds to this contract rather than the keeper.
            if (acrossData.refundAddress != _toBytes32(address(this))) revert InvalidRefundAddress();
            // V4 uses the facet-data `sendingAssetId` as the SpokePool inputToken.
            if (acrossData.sendingAssetId != _toBytes32(RAISE_TOKEN)) revert InvalidSendingAsset();
            if (acrossData.receivingAssetId != _toBytes32(BASE_WETH)) revert InvalidReceivingAsset();
            uint256 floor = amount * (BPS_DENOMINATOR - MAX_FEE_BPS) / BPS_DENOMINATOR;
            if (acrossData.outputAmount < floor) revert InsufficientOutputAmount();
            // Recheck of the facet's own receiver constraint.
            if (acrossData.receiverAddress != _toBytes32(BASE_DESTINATION)) revert InvalidReceiverAddress();
        } else {
            // Composed (Katana/Symbiosis, Fraxtal/Glacis): `BridgeData.sendingAssetId`/`minAmount` are
            // post-swap and not pinned; pin the deposited input across the `requiresDeposit` legs.
            (, ILiFi.SwapData[] memory swaps) = abi.decode(lifiCalldata[4:], (ILiFi.BridgeData, ILiFi.SwapData[]));
            uint256 sum;
            uint256 len = swaps.length;
            for (uint256 i = 0; i < len;) {
                if (swaps[i].requiresDeposit) {
                    if (swaps[i].sendingAssetId != RAISE_TOKEN) revert InvalidSendingAsset();
                    sum += swaps[i].fromAmount;
                }
                unchecked {
                    ++i;
                }
            }
            if (sum != amount) revert DepositSumMismatch();
        }
    }

    /// @notice Instantly revoke the bridge keeper. Re-enabling goes through the 7-day timelock.
    function revokeKeeper() external onlyOwner {
        address previous = keeper;
        keeper = address(0);
        // Void any in-flight keeper rotation so the halt cannot be undone by a permissionless execute.
        _cancel(ACTION_SET_KEEPER);
        emit KeeperRevoked(previous);
    }

    function signalSetKeeper(
        address newKeeper
    ) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        _signal(ACTION_SET_KEEPER, keccak256(abi.encode(newKeeper)));
    }

    function executeSetKeeper(
        address newKeeper
    ) external {
        _execute(ACTION_SET_KEEPER, keccak256(abi.encode(newKeeper)));
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }

    function cancelSetKeeper() external onlyOwner {
        _cancel(ACTION_SET_KEEPER);
    }

    /// @notice Signal adding/removing a facet selector from the allowlist.
    function signalSetSelector(
        bytes4 selector,
        bool allowed
    ) external onlyOwner {
        _signal(keccak256(abi.encode(ACTION_SET_SELECTOR, selector)), keccak256(abi.encode(allowed)));
    }

    function executeSetSelector(
        bytes4 selector,
        bool allowed
    ) external {
        _execute(keccak256(abi.encode(ACTION_SET_SELECTOR, selector)), keccak256(abi.encode(allowed)));
        allowedSelectors[selector] = allowed;
        emit SelectorSet(selector, allowed);
    }

    function cancelSetSelector(
        bytes4 selector
    ) external onlyOwner {
        _cancel(keccak256(abi.encode(ACTION_SET_SELECTOR, selector)));
    }

    /// @notice Signal a rescue of stranded assets (`token == address(0)` for native).
    function signalRescue(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _signal(keccak256(abi.encode(ACTION_RESCUE, token)), keccak256(abi.encode(to, amount)));
    }

    function executeRescue(
        address token,
        address to,
        uint256 amount
    ) external {
        _execute(keccak256(abi.encode(ACTION_RESCUE, token)), keccak256(abi.encode(to, amount)));
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert RescueFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit AssetRescued(token, to, amount);
    }

    function cancelRescue(
        address token
    ) external onlyOwner {
        _cancel(keccak256(abi.encode(ACTION_RESCUE, token)));
    }

    function _authAdmin(
        bytes32
    ) internal pure override {
        revert NotAuthorized();
    }

    function _toBytes32(
        address addr
    ) private pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}

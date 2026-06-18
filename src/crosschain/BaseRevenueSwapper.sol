// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Timelocked} from "../base/Timelocked.sol";

/// @title BaseRevenueSwapper
/// @notice Delivery target on Base for every cross-chain revenue lane. Receives bridged WETH and any
///         non-WETH raise token (e.g. frxUSD from Fraxtal); the keeper swaps the delivered `tokenIn` to
///         WETH via 0x's AllowanceHolder, then forwards the entire WETH balance to the Base `BoardwalkFeeCollector`.
contract BaseRevenueSwapper is Ownable2Step, Timelocked, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public immutable ALLOWANCE_HOLDER;
    address public immutable WETH;
    address public immutable FEE_COLLECTOR;

    bytes32 public constant ACTION_SET_KEEPER = keccak256("SWAPPER_SET_KEEPER");
    bytes32 public constant ACTION_RESCUE = keccak256("SWAPPER_RESCUE");

    address public keeper;

    error NotKeeper();
    error NotAuthorized();
    error ZeroAddress();
    error InvalidTokenIn();
    error NothingToSwap();
    error SwapCallFailed();
    error InsufficientOutput(uint256 received, uint256 required);
    error NothingToForward();
    error RescueFailed();

    event SwappedAndForwarded(address indexed tokenIn, uint256 amountIn, uint256 wethOut, uint256 wethForwarded);
    event WethForwarded(uint256 amount);
    event KeeperRevoked(address indexed previousKeeper);
    event KeeperUpdated(address indexed newKeeper);
    event AssetRescued(address indexed token, address indexed to, uint256 amount);

    constructor(
        address _owner,
        address _allowanceHolder,
        address _weth,
        address _feeCollector,
        address _keeper
    ) Ownable(_owner) {
        if (
            _allowanceHolder == address(0) || _weth == address(0) || _feeCollector == address(0)
                || _keeper == address(0)
        ) revert ZeroAddress();

        ALLOWANCE_HOLDER = _allowanceHolder;
        WETH = _weth;
        FEE_COLLECTOR = _feeCollector;
        keeper = _keeper;
    }

    /// @notice Swap the contract's full `tokenIn` balance to WETH via 0x, then
    ///         forward the entire WETH balance to the FeeCollector.
    /// @param tokenIn The raise token to swap (any non-WETH ERC20).
    /// @param zeroXCalldata The 0x AllowanceHolder calldata from the Swap API.
    /// @param minOut The minimum WETH out.
    function swapAndForward(
        address tokenIn,
        bytes calldata zeroXCalldata,
        uint256 minOut
    ) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();

        address weth = WETH;
        if (tokenIn == address(0) || tokenIn == weth) revert InvalidTokenIn();

        uint256 amount = IERC20(tokenIn).balanceOf(address(this));
        if (amount == 0) revert NothingToSwap();

        uint256 wethBefore = IERC20(weth).balanceOf(address(this));

        IERC20(tokenIn).forceApprove(ALLOWANCE_HOLDER, amount);
        (bool ok,) = ALLOWANCE_HOLDER.call(zeroXCalldata);
        if (!ok) revert SwapCallFailed();
        IERC20(tokenIn).forceApprove(ALLOWANCE_HOLDER, 0);

        uint256 wethAfter = IERC20(weth).balanceOf(address(this));
        uint256 received = wethAfter - wethBefore;
        if (received < minOut) revert InsufficientOutput(received, minOut);

        // Forward the entire WETH balance, including WETH bridged from other lanes.
        IERC20(weth).safeTransfer(FEE_COLLECTOR, wethAfter);

        emit SwappedAndForwarded(tokenIn, amount, received, wethAfter);
    }

    /// @notice Permissionless sweep of the WETH balance to the FeeCollector.
    function forwardWeth() external nonReentrant {
        uint256 balance = IERC20(WETH).balanceOf(address(this));
        if (balance == 0) revert NothingToForward();
        IERC20(WETH).safeTransfer(FEE_COLLECTOR, balance);
        emit WethForwarded(balance);
    }

    /// @notice Instantly revoke the keeper. Re-enabling goes through the 7-day timelock.
    function revokeKeeper() external onlyOwner {
        address previous = keeper;
        keeper = address(0);
        // Void any in-flight keeper rotation so the halt cannot be undone by a permissionless execute.
        _cancel(ACTION_SET_KEEPER);
        emit KeeperRevoked(previous);
    }

    /// @notice Signal a keeper change.
    function signalSetKeeper(
        address newKeeper
    ) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        _signal(ACTION_SET_KEEPER, keccak256(abi.encode(newKeeper)));
    }

    /// @notice Execute a pending keeper change.
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

    /// @dev Seals the generic Timelocked path; only the typed actions above mutate state.
    function _authAdmin(
        bytes32
    ) internal pure override {
        revert NotAuthorized();
    }
}

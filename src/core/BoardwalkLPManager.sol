// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDEXRouter} from "../interfaces/IDEXRouter.sol";
import {IDEXFactory} from "../interfaces/IDEXFactory.sol";

/// @title BoardwalkLPManager - Tax-exempt LP operations wrapper
/// @notice Singleton contract whitelisted on all Boardwalk tokens.
///         Users add/remove liquidity through this contract to avoid the token transfer tax.
///
/// @dev Restricted to pairs where at least one token is RAISE_TOKEN.
contract BoardwalkLPManager {
    using SafeERC20 for IERC20;

    // ============ Immutables ============

    address public immutable FACTORY;
    address public immutable ROUTER;
    address public immutable RAISE_TOKEN;

    // ============ Errors ============

    error ZeroLiquidity();
    error ZeroAmount();
    error ZeroAddress();
    error PairNotFound();
    error FactoryRouterMismatch();
    error InvalidPair();

    // ============ Constructor ============

    constructor(
        address _factory,
        address _router,
        address _raiseToken
    ) {
        if (_factory == address(0) || _router == address(0) || _raiseToken == address(0)) revert ZeroAddress();
        // Verify router and factory are paired
        if (IDEXRouter(_router).factory() != _factory) revert FactoryRouterMismatch();
        FACTORY = _factory;
        ROUTER = _router;
        RAISE_TOKEN = _raiseToken;
    }

    // ============ Add/Remove Liquidity ============

    /// @notice Add liquidity to a Boardwalk DEX pair, tax-free
    /// @dev At least one of tokenA/tokenB must be RAISE_TOKEN
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @param amountADesired Desired amount of tokenA to add
    /// @param amountBDesired Desired amount of tokenB to add
    /// @param amountAMin Minimum amount of tokenA to add (slippage protection)
    /// @param amountBMin Minimum amount of tokenB to add (slippage protection)
    /// @param to Address to receive LP tokens
    /// @param deadline Transaction deadline timestamp
    /// @return amountA Actual amount of tokenA added
    /// @return amountB Actual amount of tokenB added
    /// @return liquidity Amount of LP tokens minted
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        if (amountADesired == 0 || amountBDesired == 0) revert ZeroAmount();
        if (tokenA == address(0) || tokenB == address(0) || to == address(0)) revert ZeroAddress();
        if (tokenA != RAISE_TOKEN && tokenB != RAISE_TOKEN) revert InvalidPair();

        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountADesired);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountBDesired);

        IERC20(tokenA).forceApprove(ROUTER, amountADesired);
        IERC20(tokenB).forceApprove(ROUTER, amountBDesired);

        (amountA, amountB, liquidity) = IDEXRouter(ROUTER)
            .addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to, deadline);

        uint256 excessA = amountADesired - amountA;
        uint256 excessB = amountBDesired - amountB;
        if (excessA > 0) IERC20(tokenA).safeTransfer(msg.sender, excessA);
        if (excessB > 0) IERC20(tokenB).safeTransfer(msg.sender, excessB);
    }

    /// @notice Remove liquidity from a Boardwalk DEX pair, tax-free
    /// @dev At least one of tokenA/tokenB must be RAISE_TOKEN
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @param liquidity Amount of LP tokens to burn
    /// @param amountAMin Minimum amount of tokenA to receive (slippage protection)
    /// @param amountBMin Minimum amount of tokenB to receive (slippage protection)
    /// @param deadline Transaction deadline timestamp
    /// @return amountA Amount of tokenA received
    /// @return amountB Amount of tokenB received
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB) {
        if (liquidity == 0) revert ZeroLiquidity();
        if (tokenA != RAISE_TOKEN && tokenB != RAISE_TOKEN) revert InvalidPair();

        // Get the pair address (must exist)
        address pair = IDEXFactory(FACTORY).getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound();

        IERC20(pair).safeTransferFrom(msg.sender, address(this), liquidity);

        IERC20(pair).forceApprove(ROUTER, liquidity);

        // Tokens come to THIS contract (not user directly) so both legs are tax-exempt
        (amountA, amountB) = IDEXRouter(ROUTER)
            .removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, address(this), deadline);

        IERC20(tokenA).safeTransfer(msg.sender, amountA);
        IERC20(tokenB).safeTransfer(msg.sender, amountB);
    }
}

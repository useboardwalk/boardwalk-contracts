// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IBoardwalkLPManager {
    error ZeroLiquidity();
    error ZeroAmount();
    error ZeroAddress();
    error PairNotFound();
    error FactoryRouterMismatch();
    error InvalidPair();

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
    function FACTORY() external view returns (address);
    function ROUTER() external view returns (address);
    function RAISE_TOKEN() external view returns (address);
}

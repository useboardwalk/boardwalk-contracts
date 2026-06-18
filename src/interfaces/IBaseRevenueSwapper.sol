// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IBaseRevenueSwapper {
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

    function swapAndForward(
        address tokenIn,
        bytes calldata zeroXCalldata,
        uint256 minOut
    ) external;
    function forwardWeth() external;
    function revokeKeeper() external;

    function signalSetKeeper(
        address newKeeper
    ) external;
    function executeSetKeeper(
        address newKeeper
    ) external;
    function cancelSetKeeper() external;

    function signalRescue(
        address token,
        address to,
        uint256 amount
    ) external;
    function executeRescue(
        address token,
        address to,
        uint256 amount
    ) external;
    function cancelRescue(
        address token
    ) external;

    function keeper() external view returns (address);

    function ALLOWANCE_HOLDER() external view returns (address);
    function WETH() external view returns (address);
    function FEE_COLLECTOR() external view returns (address);

    function ACTION_SET_KEEPER() external view returns (bytes32);
    function ACTION_RESCUE() external view returns (bytes32);
}

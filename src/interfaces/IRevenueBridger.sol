// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IRevenueBridger {
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

    function bridgeToBase(
        uint256 amount,
        bytes calldata lifiCalldata
    ) external payable;
    function revokeKeeper() external;

    function signalSetKeeper(
        address newKeeper
    ) external;
    function executeSetKeeper(
        address newKeeper
    ) external;
    function cancelSetKeeper() external;

    function signalSetSelector(
        bytes4 selector,
        bool allowed
    ) external;
    function executeSetSelector(
        bytes4 selector,
        bool allowed
    ) external;
    function cancelSetSelector(
        bytes4 selector
    ) external;

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
    function allowedSelectors(
        bytes4 selector
    ) external view returns (bool);

    function DIAMOND() external view returns (address);
    function RAISE_TOKEN() external view returns (address);
    function BASE_DESTINATION() external view returns (address);
    function BASE_WETH() external view returns (address);
    function HAS_SOURCE_SWAPS() external view returns (bool);
    function MAX_FEE_BPS() external view returns (uint256);
    function BASE_CHAIN_ID() external view returns (uint256);
    function BPS_DENOMINATOR() external view returns (uint256);

    function ACTION_SET_KEEPER() external view returns (bytes32);
    function ACTION_SET_SELECTOR() external view returns (bytes32);
    function ACTION_RESCUE() external view returns (bytes32);
}

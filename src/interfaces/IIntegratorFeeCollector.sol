// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title IIntegratorFeeCollector
/// @notice Per-chain singleton aggregator for the integrator share of every launch's tax. Holds
///         frozen `integrators[]` + `integratorSplits[]` set at construction; `receiveFees`
///         allocates each inbound bucket per slot. Each integrator slot rate-limits claims to
///         25%/24h per token and swaps to the raise token via the standard router.
interface IIntegratorFeeCollector {
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

    function setFactory(
        address _factory
    ) external;

    /// @notice Called by any FeeDistributor to deposit the integrator bucket from a tax distribution.
    /// @dev    Gated by `factory.isLaunchToken(token) && IBoardwalkToken(token).feeDistributor() == msg.sender`.
    function receiveFees(
        address token,
        uint256 totalAmount
    ) external;

    /// @notice Claim a single token's accrued fees, swapped to the raise token. msg.sender must be
    ///         the current address recorded for the slot.
    function claim(
        address token,
        uint256 minOut,
        uint256 deadline
    ) external;

    /// @notice Claim multiple tokens in one tx. msg.sender must be the current address for the slot.
    /// @dev    Each per-token attempt is wrapped in a `try this._claimOneToken(...)` self-call so a
    ///         single failing token does not brick the batch. Tokens whose `claimableAmount == 0`
    ///         (rate-limit window not elapsed) are silently skipped without a `ClaimFailed` event.
    function claimBatch(
        address[] calldata tokens,
        uint256[] calldata minAmountsOut,
        uint256 deadline
    ) external;

    /// @notice External self-call wrapper for per-token claim attempts. Reverts if `msg.sender != address(this)`.
    function _claimOneToken(
        uint256 slotIdx,
        address token,
        uint256 minOut,
        uint256 deadline
    ) external;

    function signalChangeAddress(
        address newAddress
    ) external;

    function executeChangeAddress(
        uint256 slotIdx,
        address newAddress
    ) external;

    function cancelChangeAddress() external;

    function RAISE_TOKEN() external view returns (address);
    function ROUTER() external view returns (address);
    function factory() external view returns (address);
    function ROTATION_DELAY() external view returns (uint256);
    function ACTION_CHANGE_ADDRESS() external view returns (bytes32);
    function MAX_INTEGRATOR_SLOTS() external view returns (uint256);

    function integrators(
        uint256 slotIdx
    ) external view returns (address);
    function integratorSplits(
        uint256 slotIdx
    ) external view returns (uint256);
    function slotCount() external view returns (uint256);

    function slotOf(
        address integrator
    ) external view returns (uint256);
    function isIntegrator(
        address account
    ) external view returns (bool);

    function claimStates(
        uint256 slotIdx,
        address token
    )
        external
        view
        returns (uint256 totalAccrued, uint256 totalClaimed, uint256 claimedInCurrentPeriod, uint64 lastClaimTime);

    function claimableAmount(
        address integrator,
        address token
    ) external view returns (uint256);

    function trackedTokenCount(
        address integrator
    ) external view returns (uint256);
    function trackedTokenAt(
        address integrator,
        uint256 i
    ) external view returns (address);
    function isTracked(
        address integrator,
        address token
    ) external view returns (bool);
    function trackedTokens(
        address integrator
    ) external view returns (address[] memory);

    function quote(
        address integrator,
        address token,
        uint256 slippageBps
    ) external view returns (uint256 amountIn, uint256 minOut);

    function quoteBatch(
        address integrator,
        address[] calldata tokens,
        uint256 slippageBps
    ) external view returns (address[] memory tokens_, uint256[] memory amountsIn, uint256[] memory minAmountsOut);
}

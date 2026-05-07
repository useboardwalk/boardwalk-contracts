// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IFeeRecipientCollector {
    error UnknownSender();
    error NothingToClaim();
    error NotMyRole();

    event TokenRegistered(address indexed token, address indexed feeDistributor);
    event FeesClaimed(address indexed token, uint256 amount, address indexed to);
    event ClaimFailed(address indexed token);
    event TokenRemoved(address indexed token);

    /// @notice Best-effort registration. Caller must be the FeeDistributor that the token claims as
    ///         its own (cross-checked via `IBoardwalkToken(token).feeDistributor()`). Tokens already
    ///         arrive via the preceding `safeTransfer`; this call only adds the token to the
    ///         tracked set.
    function notifyFees(
        address token,
        uint256 amount
    ) external;

    function signalChangeOnDistributors(
        address[] calldata distributors,
        address newAddress
    ) external;
    function executeChangeOnDistributors(
        address[] calldata distributors,
        address newAddress
    ) external;
    function cancelChangeOnDistributors(
        address[] calldata distributors
    ) external;

    function trackedTokenCount() external view returns (uint256);
    function trackedTokenAt(
        uint256 i
    ) external view returns (address);
    function isTracked(
        address token
    ) external view returns (bool);
}

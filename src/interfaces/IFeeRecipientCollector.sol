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

    function notifyFees(
        address token,
        uint256 amount
    ) external;
    function batchClaim(
        uint256 limit
    ) external;
    function claimToken(
        address token
    ) external;
    function removeTrackedToken(
        address token
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

    function signalChangeOnFactory(
        address factory,
        address newAddress
    ) external;
    function cancelChangeOnFactory(
        address factory
    ) external;

    function trackedTokenCount() external view returns (uint256);
    function trackedTokenAt(
        uint256 i
    ) external view returns (address);
    function isTracked(
        address token
    ) external view returns (bool);
}

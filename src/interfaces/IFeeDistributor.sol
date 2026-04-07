// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IFeeDistributor {
    error OnlyToken();
    error NotRecipient();
    error NothingToClaimYet();
    error ZeroAddress();
    error InvalidFeeBps();
    error InvalidSplitsSum();
    error ArrayLengthMismatch();
    error OnlyFeeCollector();
    error NotIntegrator();
    error NotAuthorized();

    event TaxReceived(
        uint256 amount,
        uint256 lpShare,
        uint256 boardwalkShare,
        uint256 issuerShare,
        uint256 referrerShare,
        uint256 integratorShare
    );
    event IssuerClaimed(
        uint256 indexed recipientIdx, address indexed recipient, uint256 tokenAmount, uint256 raiseTokenAmount
    );
    event ReferrerClaimed(address indexed referrer, uint256 amount);
    event IntegratorClaimed(address indexed integrator, uint256 amount);
    event IssuerAddressChanged(uint256 indexed recipientIdx, address oldAddress, address newAddress);
    event ReferrerAddressChanged(address oldAddress, address newAddress);
    event FeeCollectorChanged(address oldCollector, address newCollector);
    event FeeForwardFailed(string target, uint256 amount);

    struct InitParams {
        address token;
        address lpStaking;
        address feeCollector;
        address router;
        address raiseToken;
        address[] issuerRecipients;
        uint256[] issuerSplits;
        address referrer;
        address integrator;
        uint256 issuerBps;
        uint256 boardwalkBps;
        uint256 lpIncentiveBps;
        uint256 referrerBps;
        uint256 integratorBps;
    }

    function initialize(
        InitParams calldata p
    ) external;
    function onTaxReceived(
        uint256 amount
    ) external;
    function claimAsRaiseToken(
        uint256 recipientIdx,
        uint256 minRaiseTokenOut,
        uint256 deadline
    ) external;
    function claimReferrerFees() external;
    function claimIntegratorFees() external;
    function claimableAmount(
        uint256 recipientIdx
    ) external view returns (uint256);
    function referrerAccrued() external view returns (uint256);
    function integratorAccrued() external view returns (uint256);
    function issuerRecipients(
        uint256 idx
    ) external view returns (address);
    function token() external view returns (address);
    function integrator() external view returns (address);
    function retryPendingFees() external;
    function pendingLpFees() external view returns (uint256);
    function pendingBoardwalkFees() external view returns (uint256);
    function feeCollector() external view returns (address);
    function setFeeCollector(
        address newFeeCollector
    ) external;
}

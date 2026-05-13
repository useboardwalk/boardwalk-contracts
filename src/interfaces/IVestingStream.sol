// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IVestingStream {
    error NotRecipient();
    error NothingToClaim();
    error CliffNotEnded(uint256 cliffEnd, uint256 currentTime);
    error NotInitializer();
    error InitializerAlreadySet();
    error ZeroAddress();
    error ArrayLengthMismatch();
    error InvalidAllocationId(uint256 id);
    error NotIssuer();

    event Claimed(uint256 indexed allocationId, address indexed recipient, uint256 amount);
    event VestingInitialized(uint256 cliffEnd, uint256 vestingEnd, uint256 allocationCount);
    event RecipientAddressChanged(uint256 indexed allocationId, address oldAddress, address newAddress);

    function setInitializer(
        address _initializer,
        address _issuer
    ) external;
    function initialize(
        address token,
        uint256 liquiditySeedTime,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external;
    function claim(
        uint256 allocationId
    ) external;
    function executeChangeRecipientAddress(
        uint256 allocationId,
        address newAddress
    ) external;
    function claimable(
        uint256 allocationId
    ) external view returns (uint256);
    function totalVested(
        uint256 allocationId
    ) external view returns (uint256);
    function allocationCount() external view returns (uint256);
    function cliffEnd() external view returns (uint256);
    function vestingEnd() external view returns (uint256);
    function issuer() external view returns (address);
}

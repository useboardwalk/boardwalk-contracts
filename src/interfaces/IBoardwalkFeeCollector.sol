// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IBoardwalkFeeCollector {
    error SwapFailed(address token);
    error NoTokensToSwap();
    error NotKeeper();
    error ArrayLengthMismatch();
    error ZeroAddress();

    event FeesReceived(address indexed token, uint256 amount);
    event FeesSwapped(address indexed token, uint256 tokenAmount, uint256 raiseTokenAmount);
    event TreasuryUpdated(address indexed newTreasury);
    event KeeperUpdated(address indexed newKeeper);
    event CollectorMigrated(address newCollector, uint256 distributorCount);
    event GovernanceVaultUpdated(address indexed newVault);

    function receiveFees(
        address token,
        uint256 amount
    ) external;
    function swapToRaiseToken(
        address[] calldata tokens,
        uint256[] calldata minAmountsOut,
        uint256 deadline
    ) external;
    function executeMigrateCollector(
        address newCollector,
        address[] calldata distributors
    ) external;
    function accumulatedFees(
        address token
    ) external view returns (uint256);
    function RAISE_TOKEN() external view returns (address);
    function ROUTER() external view returns (address);
    function treasury() external view returns (address);
    function keeper() external view returns (address);
    function governanceVault() external view returns (address);
    function GOVERNANCE_BPS() external view returns (uint256);
}

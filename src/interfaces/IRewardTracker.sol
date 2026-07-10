// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @notice Minimal interface for Morphex RewardTracker (sbfBMX / stakedBmxTracker)
/// @dev Verify function signatures against deployed Base contract ABIs before mainnet deployment
interface IRewardTracker {
    function balanceOf(
        address account
    ) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function depositBalances(
        address account,
        address depositToken
    ) external view returns (uint256);

    function stakedAmounts(
        address account
    ) external view returns (uint256);

    /// @notice Stakes `amount` of `depositToken` pulled from `fundingAccount`, crediting `account`.
    /// @dev Handler-gated on the tracker. Used by the migration contract to build staked positions
    ///      on behalf of a destination, mirroring `RewardRouterV5._stakeBmx`.
    function stakeForAccount(
        address fundingAccount,
        address account,
        address depositToken,
        uint256 amount
    ) external;
}

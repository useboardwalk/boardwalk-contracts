// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LaunchFactory} from "src/core/LaunchFactory.sol";

/// @title FeeSchedules
/// @notice Canonical per-chain factory fee defaults for Boardwalk deployments.
/// @dev `boardwalk` is stored at the Express Boardwalk rate; `referrer` is carved from boardwalk
///      on Advanced launches when a referrer is set. `total` = issuer + boardwalk + incentive +
///      INTEGRATOR_BPS (referrer is not additive to total). Token tax is `total` (115 BPS); the
///      forked DEX adds a separate 0.1% (10 BPS) pair fee → ~1.25% effective on swaps.
library FeeSchedules {
    uint256 internal constant CHAIN_ETHEREUM = 1;
    uint256 internal constant CHAIN_BASE = 8453;
    uint256 internal constant CHAIN_KATANA = 747474;
    uint256 internal constant CHAIN_FRAXTAL = 252;

    uint256 internal constant TOTAL_TAX_BPS = 115;

    error UnsupportedChainId(uint256 chainId);

    /// @notice Resolve factory defaults for `chainId`. Reverts if unsupported.
    function resolve(
        uint256 chainId
    ) internal pure returns (LaunchFactory.FeeBpsDefaults memory feeBps, uint256 integratorBps) {
        if (chainId == CHAIN_ETHEREUM) {
            return (ethereum(), 20);
        }
        if (chainId == CHAIN_BASE || chainId == CHAIN_KATANA) {
            return (baseKatana(), 27);
        }
        if (chainId == CHAIN_FRAXTAL) {
            return (fraxtal(), 25);
        }
        revert UnsupportedChainId(chainId);
    }

    /// @notice Base and Katana: issuer 30, boardwalk 35, incentive 23, referrer 5, integrator 27.
    function baseKatana() internal pure returns (LaunchFactory.FeeBpsDefaults memory) {
        return LaunchFactory.FeeBpsDefaults({
            issuer: 30,
            boardwalk: 35,
            incentive: 23,
            referrer: 5,
            total: TOTAL_TAX_BPS
        });
    }

    /// @notice Fraxtal mainnet: issuer 30, boardwalk 35, incentive 25, referrer 5, integrator 25.
    function fraxtal() internal pure returns (LaunchFactory.FeeBpsDefaults memory) {
        return LaunchFactory.FeeBpsDefaults({
            issuer: 30,
            boardwalk: 35,
            incentive: 25,
            referrer: 5,
            total: TOTAL_TAX_BPS
        });
    }

    /// @notice Ethereum mainnet: issuer 35, boardwalk 35, incentive 25, referrer 5, integrator 20.
    function ethereum() internal pure returns (LaunchFactory.FeeBpsDefaults memory) {
        return LaunchFactory.FeeBpsDefaults({
            issuer: 35,
            boardwalk: 35,
            incentive: 25,
            referrer: 5,
            total: TOTAL_TAX_BPS
        });
    }
}

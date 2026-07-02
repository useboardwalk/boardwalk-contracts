// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LaunchFactory} from "src/core/LaunchFactory.sol";

/// @title FeeSchedules
/// @notice Canonical per-chain factory fee defaults and integrator recipients for Boardwalk
///         deployments.
/// @dev `boardwalk` is stored at the Express Boardwalk rate; `referrer` is carved from boardwalk
///      on Advanced launches when a referrer is set. `total` = issuer + boardwalk + incentive +
///      INTEGRATOR_BPS (referrer is not additive to total). Token tax is `total` (115 BPS); the
///      forked DEX adds a separate 0.1% (10 BPS) pair fee → ~1.25% effective on swaps.
library FeeSchedules {
    uint256 internal constant CHAIN_ETHEREUM = 1;
    uint256 internal constant CHAIN_BASE = 8453;
    uint256 internal constant CHAIN_KATANA = 747474;
    uint256 internal constant CHAIN_FRAXTAL = 252;
    uint256 internal constant CHAIN_INK = 57073;
    uint256 internal constant CHAIN_ARBITRUM = 42161;

    uint256 internal constant TOTAL_TAX_BPS = 115;
    uint256 internal constant SPLITS_DENOMINATOR = 10_000;

    error UnsupportedChainId(uint256 chainId);

    /// @notice Resolve factory fee defaults for `chainId`. Reverts if unsupported.
    /// @param chainId The chain to resolve fee defaults for.
    /// @return feeBps The frozen per-launch fee bucket sizes (issuer/boardwalk/incentive/referrer/total).
    /// @return integratorBps The immutable integrator bucket size in BPS of the token tax.
    function resolve(
        uint256 chainId
    ) internal pure returns (LaunchFactory.FeeBpsDefaults memory feeBps, uint256 integratorBps) {
        if (chainId == CHAIN_ETHEREUM) {
            return (ethereum(), 20);
        }
        if (chainId == CHAIN_BASE || chainId == CHAIN_KATANA || chainId == CHAIN_INK || chainId == CHAIN_ARBITRUM) {
            return (baseKatanaInk(), 27);
        }
        if (chainId == CHAIN_FRAXTAL) {
            return (fraxtal(), 25);
        }
        revert UnsupportedChainId(chainId);
    }

    /// @notice Base, Katana, Ink, Arbitrum: issuer 30, boardwalk 35, incentive 23, referrer 5, integrator 27.
    function baseKatanaInk() internal pure returns (LaunchFactory.FeeBpsDefaults memory) {
        return
            LaunchFactory.FeeBpsDefaults({issuer: 30, boardwalk: 35, incentive: 23, referrer: 5, total: TOTAL_TAX_BPS});
    }

    /// @notice Fraxtal mainnet: issuer 30, boardwalk 35, incentive 25, referrer 5, integrator 25.
    function fraxtal() internal pure returns (LaunchFactory.FeeBpsDefaults memory) {
        return
            LaunchFactory.FeeBpsDefaults({issuer: 30, boardwalk: 35, incentive: 25, referrer: 5, total: TOTAL_TAX_BPS});
    }

    /// @notice Ethereum mainnet: issuer 35, boardwalk 35, incentive 25, referrer 5, integrator 20.
    function ethereum() internal pure returns (LaunchFactory.FeeBpsDefaults memory) {
        return
            LaunchFactory.FeeBpsDefaults({issuer: 35, boardwalk: 35, incentive: 25, referrer: 5, total: TOTAL_TAX_BPS});
    }

    /// @notice Per-chain integrator recipients with their split (BPS of the integrator bucket).
    /// @dev Splits are derived from each integrator's absolute tax bps and always sum to 10_000.
    ///      The final slot absorbs integer-division dust, mirroring IntegratorFeeCollector._allocate.
    ///      `totalBps` cross-checks against `resolve()`'s integratorBps at the deploy site.
    /// @param chainId The chain to resolve integrators for.
    /// @return addrs The integrator recipient addresses (frozen at IntegratorFeeCollector construction).
    /// @return splits The per-slot split in BPS of the integrator bucket (sums to 10_000).
    /// @return totalBps The integrator bucket size in BPS of the token tax (== resolve()'s integratorBps).
    function integratorConfig(
        uint256 chainId
    ) internal pure returns (address[] memory addrs, uint256[] memory splits, uint256 totalBps) {
        uint256[] memory absBps;
        (addrs, absBps) = _integrators(chainId);

        uint256 len = absBps.length;
        splits = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            totalBps += absBps[i];
        }

        uint256 running;
        for (uint256 i; i + 1 < len; ++i) {
            splits[i] = absBps[i] * SPLITS_DENOMINATOR / totalBps;
            running += splits[i];
        }
        splits[len - 1] = SPLITS_DENOMINATOR - running;
    }

    /// @dev Per-chain integrator recipients and their absolute tax bps (the integrator carve-out
    ///      of the 115 BPS token tax). The summed bps equal `resolve()`'s integratorBps per chain.
    function _integrators(
        uint256 chainId
    ) private pure returns (address[] memory addrs, uint256[] memory absBps) {
        if (chainId == CHAIN_ETHEREUM) {
            addrs = new address[](4);
            absBps = new uint256[](4);
            // Sherlock
            addrs[0] = 0xd35F65B1f0912bD13a07A21374615cfeC073Dc67;
            absBps[0] = 8;
            // Boardwalk security fund msig
            addrs[1] = 0xE0DE2EF17A9D6022c67fb9AAabCB824F31254Ce8;
            absBps[1] = 5;
            // 0x
            addrs[2] = 0x3C241dAF101F697044ee076B51baEe5B0d72c0dc;
            absBps[2] = 2;
            // DefiLlama
            addrs[3] = 0x08a3c2A819E3de7ACa384c798269B3Ce1CD0e437;
            absBps[3] = 5;
            return (addrs, absBps);
        }
        if (chainId == CHAIN_BASE) {
            addrs = new address[](2);
            absBps = new uint256[](2);
            // Base
            addrs[0] = 0x14536667Cd30e52C0b458BaACcB9faDA7046E056;
            absBps[0] = 25;
            // 0x
            addrs[1] = 0x3C241dAF101F697044ee076B51baEe5B0d72c0dc;
            absBps[1] = 2;
            return (addrs, absBps);
        }
        if (chainId == CHAIN_KATANA) {
            addrs = new address[](2);
            absBps = new uint256[](2);
            // Katana
            addrs[0] = 0xdB579446097D33A809dAf8aCecfDd29A1c239935;
            absBps[0] = 25;
            // Boardwalk msig holding 0x's fee on Katana until 0x deploys
            addrs[1] = 0xE0DE2EF17A9D6022c67fb9AAabCB824F31254Ce8;
            absBps[1] = 2;
            return (addrs, absBps);
        }
        if (chainId == CHAIN_FRAXTAL) {
            addrs = new address[](1);
            absBps = new uint256[](1);
            // Frax
            addrs[0] = 0xC4EB45d80DC1F079045E75D5d55de8eD1c1090E6;
            absBps[0] = 25;
            return (addrs, absBps);
        }
        if (chainId == CHAIN_INK) {
            addrs = new address[](2);
            absBps = new uint256[](2);
            // Ink
            addrs[0] = 0x8e7Def02a84534F9D799f375CF94CC763A53F8b2;
            absBps[0] = 25;
            // 0x
            addrs[1] = 0x3C241dAF101F697044ee076B51baEe5B0d72c0dc;
            absBps[1] = 2;
            return (addrs, absBps);
        }
        if (chainId == CHAIN_ARBITRUM) {
            addrs = new address[](2);
            absBps = new uint256[](2);
            // Arbitrum Foundation
            addrs[0] = 0xF3FC178157fb3c87548bAA86F9d24BA38E649B58;
            absBps[0] = 25;
            // 0x
            addrs[1] = 0x3C241dAF101F697044ee076B51baEe5B0d72c0dc;
            absBps[1] = 2;
            return (addrs, absBps);
        }
        revert UnsupportedChainId(chainId);
    }
}

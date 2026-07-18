// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LaunchFactory} from "src/core/LaunchFactory.sol";

/// @title FeeSchedules
/// @notice Canonical per-chain factory fee defaults and integrator recipients for Boardwalk
///         deployments.
/// @dev One standardized schedule applies on every supported chain (Ethereum, Base, Arbitrum,
///      Robinhood). `boardwalk` is stored at the Express Boardwalk rate; `referrer` is carved from
///      boardwalk on Advanced launches when a referrer is set. `total` = issuer + boardwalk +
///      incentive + INTEGRATOR_BPS (referrer is not additive to total). Token tax is `total`
///      (95 BPS); Uniswap V2 adds its own 0.30% pair fee (split 0.25% LP / 0.05% protocol where
///      the fee switch is on) → 1.25% effective on swaps.
library FeeSchedules {
    uint256 internal constant CHAIN_ETHEREUM = 1;
    uint256 internal constant CHAIN_BASE = 8453;
    uint256 internal constant CHAIN_ARBITRUM = 42161;
    uint256 internal constant CHAIN_ROBINHOOD = 4663;

    uint256 internal constant TOTAL_TAX_BPS = 95;
    uint256 internal constant SPLITS_DENOMINATOR = 10_000;

    /// @notice Sentinel for an integrator whose address is not yet confirmed. The deploy script
    ///         must replace it (env-supplied) before broadcasting; the IntegratorFeeCollector
    ///         constructor rejects address(0) as a backstop.
    address internal constant PENDING_INTEGRATOR = address(0);

    error UnsupportedChainId(uint256 chainId);

    /// @notice Resolve factory fee defaults for `chainId`. Reverts if unsupported.
    /// @param chainId The chain to resolve fee defaults for.
    /// @return feeBps The frozen per-launch fee bucket sizes (issuer/boardwalk/incentive/referrer/total).
    /// @return integratorBps The immutable integrator bucket size in BPS of the token tax.
    function resolve(
        uint256 chainId
    ) internal pure returns (LaunchFactory.FeeBpsDefaults memory feeBps, uint256 integratorBps) {
        if (
            chainId == CHAIN_ETHEREUM || chainId == CHAIN_BASE || chainId == CHAIN_ARBITRUM
                || chainId == CHAIN_ROBINHOOD
        ) {
            return (unified(), 10);
        }
        revert UnsupportedChainId(chainId);
    }

    /// @notice All chains: issuer 35, boardwalk 35 (Express; Advanced-with-referrer 30 + 5),
    ///         incentive 15, integrator 10.
    function unified() internal pure returns (LaunchFactory.FeeBpsDefaults memory) {
        return
            LaunchFactory.FeeBpsDefaults({issuer: 35, boardwalk: 35, incentive: 15, referrer: 5, total: TOTAL_TAX_BPS});
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
    ///      of the 95 BPS token tax). The summed bps equal `resolve()`'s integratorBps per chain.
    ///      The five slots are identical on every chain today (each integrator has confirmed, or is
    ///      assumed to confirm, one address across chains); the per-chain structure is kept so a
    ///      chain-specific address can be pinned without reshaping the schedule.
    function _integrators(
        uint256 chainId
    ) private pure returns (address[] memory addrs, uint256[] memory absBps) {
        if (
            chainId == CHAIN_ETHEREUM || chainId == CHAIN_BASE || chainId == CHAIN_ARBITRUM
                || chainId == CHAIN_ROBINHOOD
        ) {
            addrs = new address[](5);
            absBps = new uint256[](5);
            // Sherlock
            addrs[0] = 0xd35F65B1f0912bD13a07A21374615cfeC073Dc67;
            absBps[0] = 2;
            // DefiLlama Research (address not yet confirmed; supplied via DEFILLAMA_RESEARCH_ADDRESS
            // at deploy time)
            addrs[1] = PENDING_INTEGRATOR;
            absBps[1] = 2;
            // 0x
            addrs[2] = 0x3C241dAF101F697044ee076B51baEe5B0d72c0dc;
            absBps[2] = 2;
            // Security Alliance (SEAL) — public-goods donation. The confirmed address is a Gnosis
            // Safe with code on Ethereum ONLY (verified July 2026); a codeless contract wallet can
            // neither claim nor rotate its frozen slot, so on every other chain the slot stays
            // PENDING (filled from SEAL_ADDRESS at deploy, fail-loud) until SEAL confirms a
            // per-chain-usable address.
            addrs[3] = chainId == CHAIN_ETHEREUM ? 0x5EA1d9A6dDC3A0329378a327746D71A2019eC332 : PENDING_INTEGRATOR;
            absBps[3] = 2;
            // DeFi Llama — public-goods donation. Address confirmed for Ethereum only; on every
            // other chain the slot stays PENDING (filled from DEFILLAMA_ADDRESS at deploy,
            // fail-loud) until DeFi Llama confirms a per-chain address.
            addrs[4] = chainId == CHAIN_ETHEREUM ? 0x08a3c2A819E3de7ACa384c798269B3Ce1CD0e437 : PENDING_INTEGRATOR;
            absBps[4] = 2;
            return (addrs, absBps);
        }
        revert UnsupportedChainId(chainId);
    }
}

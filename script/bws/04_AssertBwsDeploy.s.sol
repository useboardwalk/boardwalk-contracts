// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BwsMigration} from "src/token/BwsMigration.sol";
import {UnsoldBurner} from "src/token/UnsoldBurner.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {ArbitrumConfig} from "./ArbitrumConfig.sol";

/// @dev Introspection surface of a BWS staking `RewardTracker` (solc 0.6.12, Governable). These getters
///      are not part of the minimal production `IRewardTracker`, so they live here for go-live checks.
interface IRewardTrackerIntrospect {
    function isHandler(
        address
    ) external view returns (bool);
    function isDepositToken(
        address
    ) external view returns (bool);
    function gov() external view returns (address);
    function isInitialized() external view returns (bool);
    function distributor() external view returns (address);
    function inPrivateTransferMode() external view returns (bool);
    function inPrivateStakingMode() external view returns (bool);
    function depositBalances(
        address,
        address
    ) external view returns (uint256);
    function stakedAmounts(
        address
    ) external view returns (uint256);
    function balanceOf(
        address
    ) external view returns (uint256);
}

/// @dev Introspection surface of the bnBWS `MintableBaseToken` (Governable, BaseToken).
interface IMintableBaseTokenIntrospect {
    function isMinter(
        address
    ) external view returns (bool);
    function isHandler(
        address
    ) external view returns (bool);
    function inPrivateTransferMode() external view returns (bool);
    function gov() external view returns (address);
}

/// @dev Introspection surface of a BWS staking `RewardDistributor` (each tracker's reward source).
interface IRewardDistributorIntrospect {
    function rewardTracker() external view returns (address);
}

/// @dev CCA auction getters the launch-wiring section reads (ContinuousClearingAuction).
interface ICcaAuctionIntrospect {
    function token() external view returns (address);
    function tokensRecipient() external view returns (address);
    function totalSupply() external view returns (uint128);
}

/// @dev Minimal ERC20 metadata surface for the BMX standardness check.
interface IERC20Meta {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function totalSupply() external view returns (uint256);
}

/// @title AssertBwsDeploy - The go-live gate for the BMX -> BWS Arbitrum deployment
/// @notice The migration contracts do not assert their deploy-time wiring. This script is that gate:
///         `assertAll` reverts unless every D-1..D-5 + F-1 invariant holds. Run it on a fork (or against
///         live addresses) immediately before going live; a revert blocks go-live.
/// @dev `assertAll(Config)` is `view` and takes every input explicitly so it is exercisable from tests
///      (pass a correctly-wired config -> passes; corrupt one field -> reverts with the matching
///      error). `run()` is the env-driven CLI wrapper.
contract AssertBwsDeploy is Script {
    struct Config {
        address migrator;
        address voter;
        address bws;
        address bmx;
        address stakedBwsTracker;
        address bonusBwsTracker;
        address feeBwsTracker;
        address bnBws;
        address timelock; // expected migrator owner (the 21-day governance timelock)
        address stakingGov; // expected gov of the three trackers + bnBWS (multisig/timelock, NOT a hot key)
        address auction; // CCA auction (0 = skip A-1..A-4; only before the launch exists)
        address burner; // UnsoldBurner (checked with the auction)
        address lpLocker; // LPLocker (0 = skip A-5..A-7; only before the launch exists)
        uint256 totalMigratableBmx; // reconciled global BMX that can be brought to Arbitrum (D-1)
        bytes32 expectedTrackerCodehash; // BWS staking RewardTracker runtime codehash (D-4)
        bytes32 expectedBnTokenCodehash; // bnBWS MintableBaseToken runtime codehash (D-4, 0 = skip)
        bool bmxEmissionsHaltedAttested; // D-1: BMX has no live minter on any chain (manual attest)
        bool bmxStandardAttested; // D-5: BMX is non-fee-on-transfer (proven in fork test / off-chain)
    }

    // ---- D-1 ----
    error D1_PoolUndersized(uint256 poolBalance, uint256 required);
    error D1_EmissionsNotAttested();
    error D1_ZeroMigratable();
    // ---- D-2 ----
    error D2_VoterFeeTrackerMismatch(address voterSbf, address migratorFee);
    error D2_MigratorVoterMismatch(address migratorVoter, address voter);
    error D2_StakedTrackerMismatch(address voterStaked, address migratorStaked);
    error D2_BonusTrackerMismatch(address migratorBonus, address cfgBonus);
    error D2_BnTokenMismatch(address voterBn, address migratorBn);
    error D2_TokenMismatch(address voterToken, address migratorBws);
    error D2_BmxMismatch(address migratorBmx, address cfgBmx);
    error D2_TrackersNotDistinct();
    error D2_BwsSupplyWrong(uint256 actual, uint256 expected);
    // ---- D-3 ----
    error D3_MigratorNotHandler(address tracker);
    error D3_MigratorNotMinter(address bnBws);
    error D3_TrackerNotWired(address tracker, address expectedHandler);
    error D3_DepositTokenUnset(address tracker, address depositToken);
    error D3_FeeTrackerNotBnHandler(address bnBws, address feeTracker);
    error D3_TrackerNotInitialized(address tracker);
    error D3_DistributorMismatch(address tracker, address distributor);
    error D3_TrackerPrivateModeOff(address tracker);
    // ---- D-4 ----
    error D4_NoCode(address target);
    error D4_TrackerCodehashMismatch(address tracker, bytes32 actual, bytes32 expected);
    error D4_BnTokenCodehashMismatch(address bnBws, bytes32 actual, bytes32 expected);
    error D4_SelectorMissing(address tracker, string selector);
    // ---- D-5 ----
    error D5_BmxNotStandard(address bmx, uint8 decimals);
    error D5_BmxNotAttested();
    // ---- F-1 / go-live readiness ----
    error F1_OwnerNotTimelock(address owner, address timelock);
    error F1_StakingGovNotExpected(address target, address gov, address expected);
    error F1_TimelockHasNoCode(address timelock);
    error GoLive_RootNotSet();
    error GoLive_ClaimWindowClosed(uint256 deadline, uint256 nowTs);
    error GoLive_ClaimWindowImplausible(uint256 deadline);
    // ---- A (CCA launch wiring; checked when cfg.auction / cfg.lpLocker are set) ----
    error A1_AuctionTokenMismatch(address auctionToken, address bws);
    error A2_TokensRecipientNotBurner(address recipient, address burner);
    error A3_BurnerBwsMismatch(address burnerBws, address bws);
    error A4_AuctionSupplyUnexpected(uint256 auctionSupply, uint256 expected);
    error A5_PoolHooksNotCommitted();
    error A6_RegistrarNotRenounced(address registrar);
    error A7_LockerWiringMismatch();
    error A8_LockerNotVoterPeer(address voterLocker, address cfgLocker);
    error AuctionBurnerEnvPairIncomplete(address auction, address burner);
    error WrongChain(uint256 chainId);

    function run() external view {
        if (block.chainid != ArbitrumConfig.ARBITRUM_CHAIN_ID) revert WrongChain(block.chainid);
        // Field-by-field assignment: a single struct literal with this many env reads is
        // stack-too-deep for the legacy pipeline.
        Config memory cfg;
        cfg.migrator = vm.envAddress("MIGRATOR");
        cfg.voter = vm.envAddress("GOVERNANCE_VOTER");
        cfg.bws = vm.envAddress("BWS_TOKEN");
        cfg.bmx = vm.envOr("BMX_ADDRESS", ArbitrumConfig.ARB_BMX);
        cfg.stakedBwsTracker = vm.envAddress("STAKED_BWS_TRACKER");
        cfg.bonusBwsTracker = vm.envAddress("BONUS_BWS_TRACKER");
        cfg.feeBwsTracker = vm.envAddress("FEE_BWS_TRACKER");
        cfg.bnBws = vm.envAddress("BN_BWS");
        cfg.timelock = vm.envAddress("OWNER");
        cfg.stakingGov = vm.envAddress("STAKING_GOV");
        cfg.auction = vm.envOr("CCA_AUCTION", address(0));
        cfg.burner = vm.envOr("UNSOLD_BURNER", address(0));
        // The pair is checked as a unit; one without the other is a forgotten env, not a skip.
        if ((cfg.auction == address(0)) != (cfg.burner == address(0))) {
            revert AuctionBurnerEnvPairIncomplete(cfg.auction, cfg.burner);
        }
        cfg.lpLocker = vm.envOr("LP_LOCKER", address(0));
        // Required: the reconciled migratable figure (no silent default - a wrong value here is the
        // failure D-1 guards against). Live summed BMX totalSupply was ~3,041,989e18.
        cfg.totalMigratableBmx = vm.envUint("TOTAL_MIGRATABLE_BMX");
        cfg.expectedTrackerCodehash =
            vm.envOr("EXPECTED_TRACKER_CODEHASH", ArbitrumConfig.REFERENCE_REWARD_TRACKER_CODEHASH);
        cfg.expectedBnTokenCodehash =
            vm.envOr("EXPECTED_BN_CODEHASH", ArbitrumConfig.REFERENCE_MINTABLE_BASE_TOKEN_CODEHASH);
        cfg.bmxEmissionsHaltedAttested = vm.envOr("BMX_EMISSIONS_HALTED_ATTESTED", false);
        cfg.bmxStandardAttested = vm.envOr("BMX_STANDARD_ATTESTED", false);

        assertAll(cfg);

        console.log("BWS migration go-live gate: ALL ASSERTIONS PASSED.");
        if (cfg.auction == address(0)) {
            console.log("WARNING: CCA_AUCTION/UNSOLD_BURNER unset - launch wiring (A-1..A-4) NOT checked.");
        }
        if (cfg.lpLocker == address(0)) {
            console.log("WARNING: LP_LOCKER unset - governance one-shots (A-5..A-7) NOT checked.");
        }
        console.log("Reminder (F-1, not code-enforceable): after migration + sweep, REVOKE the");
        console.log("migrator's bnBWS minter role to cap point inflation.");
    }

    /// @notice Reverts unless every go-live invariant (D-1..D-5, F-1) holds for `cfg`.
    function assertAll(
        Config memory cfg
    ) public view {
        _assertD1(cfg);
        _assertD2(cfg);
        _assertD3(cfg);
        _assertD4(cfg);
        _assertD5(cfg);
        _assertF1AndReadiness(cfg);
        _assertCcaWiring(cfg);
    }

    /// @dev D-1: the pool covers all migratable BMX, and BMX emissions are halted everywhere.
    function _assertD1(
        Config memory cfg
    ) internal view {
        // A zeroed/typo'd TOTAL_MIGRATABLE_BMX would make the pool check below vacuously true.
        if (cfg.totalMigratableBmx == 0) revert D1_ZeroMigratable();
        uint256 poolBalance = IERC20(cfg.bws).balanceOf(cfg.migrator);
        if (poolBalance < cfg.totalMigratableBmx) {
            revert D1_PoolUndersized(poolBalance, cfg.totalMigratableBmx);
        }
        // BMX has no live minter on any chain. Not fully provable on-chain (a spoke BMX may be a CCIP
        // burn/mint token whose minter is the local pool), so this is an explicit operator attestation.
        if (!cfg.bmxEmissionsHaltedAttested) revert D1_EmissionsNotAttested();
    }

    /// @dev D-2: the voter, migrator, trackers and bnBWS are one coherent deployment.
    function _assertD2(
        Config memory cfg
    ) internal view {
        GovernanceVoter voter = GovernanceVoter(payable(cfg.voter));
        BwsMigration migrator = BwsMigration(cfg.migrator);

        // Shape check first: cfg.bws must look like the genuine fixed-supply BWS. This cannot
        // distinguish a byte-identical second deployment - A-1 (auction.token()) is the anchor to
        // the launched instance - but it catches a self-consistent stack built on a wrong token.
        uint256 bwsSupply = IERC20Meta(cfg.bws).totalSupply();
        if (bwsSupply != ArbitrumConfig.TOTAL_SUPPLY) {
            revert D2_BwsSupplyWrong(bwsSupply, ArbitrumConfig.TOTAL_SUPPLY);
        }

        address voterSbf = address(voter.SBF_BMX());
        address migratorFee = address(migrator.FEE_BWS_TRACKER());
        if (voterSbf != migratorFee) revert D2_VoterFeeTrackerMismatch(voterSbf, migratorFee);
        if (voterSbf != cfg.feeBwsTracker) revert D2_VoterFeeTrackerMismatch(voterSbf, cfg.feeBwsTracker);

        if (migrator.VOTER() != cfg.voter) revert D2_MigratorVoterMismatch(migrator.VOTER(), cfg.voter);

        address voterStaked = address(voter.STAKED_BMX_TRACKER());
        address migratorStaked = address(migrator.STAKED_BWS_TRACKER());
        if (voterStaked != migratorStaked) revert D2_StakedTrackerMismatch(voterStaked, migratorStaked);
        if (voterStaked != cfg.stakedBwsTracker) revert D2_StakedTrackerMismatch(voterStaked, cfg.stakedBwsTracker);

        // The bonus tracker is anchored only to the migrator's own immutable (the voter does not
        // reference it), so without this the gate would never tie the middle tier to the migrator -
        // a migrator built with the wrong bonus tracker would pass the gate but revert in `migrate`.
        address migratorBonus = address(migrator.BONUS_BWS_TRACKER());
        if (migratorBonus != cfg.bonusBwsTracker) revert D2_BonusTrackerMismatch(migratorBonus, cfg.bonusBwsTracker);

        address voterBn = voter.BN_BMX();
        address migratorBn = address(migrator.BN_BWS());
        if (voterBn != migratorBn) revert D2_BnTokenMismatch(voterBn, migratorBn);
        if (voterBn != cfg.bnBws) revert D2_BnTokenMismatch(voterBn, cfg.bnBws);

        address voterToken = voter.BMX();
        address migratorBws = address(migrator.BWS());
        if (voterToken != migratorBws) revert D2_TokenMismatch(voterToken, migratorBws);
        if (voterToken != cfg.bws) revert D2_TokenMismatch(voterToken, cfg.bws);

        // The token D-5 attests must be the one `migrate` actually surrenders.
        address migratorBmx = address(migrator.BMX());
        if (migratorBmx != cfg.bmx) revert D2_BmxMismatch(migratorBmx, cfg.bmx);

        // The three tiers must be distinct contracts (a bonus that aliases staked/fee bricks staking).
        if (migratorStaked == migratorBonus || migratorStaked == migratorFee || migratorBonus == migratorFee) {
            revert D2_TrackersNotDistinct();
        }
    }

    /// @dev D-3: the migrator holds the handler/minter roles and the 3-tier is fully wired.
    function _assertD3(
        Config memory cfg
    ) internal view {
        IRewardTrackerIntrospect staked = IRewardTrackerIntrospect(cfg.stakedBwsTracker);
        IRewardTrackerIntrospect bonus = IRewardTrackerIntrospect(cfg.bonusBwsTracker);
        IRewardTrackerIntrospect fee = IRewardTrackerIntrospect(cfg.feeBwsTracker);

        // Migrator is a handler on all three trackers (to call stakeForAccount).
        if (!staked.isHandler(cfg.migrator)) revert D3_MigratorNotHandler(cfg.stakedBwsTracker);
        if (!bonus.isHandler(cfg.migrator)) revert D3_MigratorNotHandler(cfg.bonusBwsTracker);
        if (!fee.isHandler(cfg.migrator)) revert D3_MigratorNotHandler(cfg.feeBwsTracker);

        // Migrator is a minter on bnBWS (to mint the point credit).
        if (!IMintableBaseTokenIntrospect(cfg.bnBws).isMinter(cfg.migrator)) {
            revert D3_MigratorNotMinter(cfg.bnBws);
        }

        // Trackers handler-wired to each other: the bonus tier pulls staked-tracker tokens from the
        // account, and the fee tier pulls bonus-tracker tokens - each via the handler transfer bypass.
        if (!staked.isHandler(cfg.bonusBwsTracker)) {
            revert D3_TrackerNotWired(cfg.stakedBwsTracker, cfg.bonusBwsTracker);
        }
        if (!bonus.isHandler(cfg.feeBwsTracker)) {
            revert D3_TrackerNotWired(cfg.bonusBwsTracker, cfg.feeBwsTracker);
        }

        // Deposit tokens: BWS on staked; the prior tier on each next; bnBWS on fee.
        if (!staked.isDepositToken(cfg.bws)) revert D3_DepositTokenUnset(cfg.stakedBwsTracker, cfg.bws);
        if (!bonus.isDepositToken(cfg.stakedBwsTracker)) {
            revert D3_DepositTokenUnset(cfg.bonusBwsTracker, cfg.stakedBwsTracker);
        }
        if (!fee.isDepositToken(cfg.bonusBwsTracker)) {
            revert D3_DepositTokenUnset(cfg.feeBwsTracker, cfg.bonusBwsTracker);
        }
        if (!fee.isDepositToken(cfg.bnBws)) revert D3_DepositTokenUnset(cfg.feeBwsTracker, cfg.bnBws);

        // If bnBWS is in private transfer mode, the fee tracker must be a handler on it so the migrator's
        // freshly-minted bnBWS can be pulled into the fee tier during the point credit.
        if (
            IMintableBaseTokenIntrospect(cfg.bnBws).inPrivateTransferMode()
                && !IMintableBaseTokenIntrospect(cfg.bnBws).isHandler(cfg.feeBwsTracker)
        ) {
            revert D3_FeeTrackerNotBnHandler(cfg.bnBws, cfg.feeBwsTracker);
        }

        // Each tracker must be initialize()d with a distributor wired back to it: RewardTracker._stake
        // calls distributor.distribute() before crediting, so an unset distributor makes every
        // migrate()/creditPoints() revert, and initialize() is one-shot (a wrong distributor means a
        // tracker redeploy). setHandler/setDepositToken work without initialize(), so the checks above
        // cannot catch this.
        _assertTrackerDistributor(cfg.stakedBwsTracker);
        _assertTrackerDistributor(cfg.bonusBwsTracker);
        _assertTrackerDistributor(cfg.feeBwsTracker);

        // Live Base runs both private modes on all three trackers. Left default-false, tracker
        // tokens are freely transferable ERC20s and voting weight can be shuffled between
        // addresses within an epoch.
        _assertPrivateModes(cfg.stakedBwsTracker);
        _assertPrivateModes(cfg.bonusBwsTracker);
        _assertPrivateModes(cfg.feeBwsTracker);
    }

    function _assertPrivateModes(
        address tracker
    ) internal view {
        IRewardTrackerIntrospect t = IRewardTrackerIntrospect(tracker);
        if (!t.inPrivateTransferMode() || !t.inPrivateStakingMode()) {
            revert D3_TrackerPrivateModeOff(tracker);
        }
    }

    function _assertTrackerDistributor(
        address tracker
    ) internal view {
        IRewardTrackerIntrospect t = IRewardTrackerIntrospect(tracker);
        if (!t.isInitialized()) revert D3_TrackerNotInitialized(tracker);
        address dist = t.distributor();
        if (dist == address(0) || IRewardDistributorIntrospect(dist).rewardTracker() != tracker) {
            revert D3_DistributorMismatch(tracker, dist);
        }
    }

    /// @dev D-4: the deployed trackers byte-match the BWS staking RewardTracker, and the IRewardTracker
    ///      view selectors respond. Codehash equality is a full byte-match (RewardTracker has no
    ///      immutables, so a faithful redeploy reproduces the runtime bytecode exactly).
    function _assertD4(
        Config memory cfg
    ) internal view {
        _assertTrackerCode(cfg.stakedBwsTracker, cfg.expectedTrackerCodehash);
        _assertTrackerCode(cfg.bonusBwsTracker, cfg.expectedTrackerCodehash);
        _assertTrackerCode(cfg.feeBwsTracker, cfg.expectedTrackerCodehash);

        if (cfg.expectedBnTokenCodehash != bytes32(0)) {
            if (cfg.bnBws.code.length == 0) revert D4_NoCode(cfg.bnBws);
            bytes32 bnHash = cfg.bnBws.codehash;
            if (bnHash != cfg.expectedBnTokenCodehash) {
                revert D4_BnTokenCodehashMismatch(cfg.bnBws, bnHash, cfg.expectedBnTokenCodehash);
            }
        }
    }

    function _assertTrackerCode(
        address tracker,
        bytes32 expectedCodehash
    ) internal view {
        if (tracker.code.length == 0) revert D4_NoCode(tracker);
        bytes32 actual = tracker.codehash;
        if (actual != expectedCodehash) revert D4_TrackerCodehashMismatch(tracker, actual, expectedCodehash);

        // Probe the IRewardTracker view selectors (depositBalances / stakedAmounts / balanceOf). A
        // codehash match already implies the full ABI; this is a redundant check.
        (bool a,) = tracker.staticcall(abi.encodeWithSignature("depositBalances(address,address)", tracker, tracker));
        if (!a) revert D4_SelectorMissing(tracker, "depositBalances");
        (bool b,) = tracker.staticcall(abi.encodeWithSignature("stakedAmounts(address)", tracker));
        if (!b) revert D4_SelectorMissing(tracker, "stakedAmounts");
        (bool c,) = tracker.staticcall(abi.encodeWithSignature("balanceOf(address)", tracker));
        if (!c) revert D4_SelectorMissing(tracker, "balanceOf");
    }

    /// @dev D-5: BMX is a standard ERC20 (18 decimals, has code). Non-fee-on-transfer is proven in the
    ///      fork test (transfer balance-delta) and re-attested off-chain.
    function _assertD5(
        Config memory cfg
    ) internal view {
        if (cfg.bmx.code.length == 0) revert D4_NoCode(cfg.bmx);
        uint8 dec = IERC20Meta(cfg.bmx).decimals();
        if (dec != 18) revert D5_BmxNotStandard(cfg.bmx, dec);
        if (!cfg.bmxStandardAttested) revert D5_BmxNotAttested();
    }

    /// @dev F-1 ops backstop + go-live readiness: owner is the timelock, root is set, window is open,
    ///      and the staking gov roles are on the expected multisig/timelock. Tracker gov can
    ///      withdrawToken (the entire migrated staked-BWS custody) and setHandler; bnBWS gov can
    ///      re-grant minters — none of that may sit on a deploy hot key at go-live.
    function _assertF1AndReadiness(
        Config memory cfg
    ) internal view {
        BwsMigration migrator = BwsMigration(cfg.migrator);
        if (migrator.owner() != cfg.timelock) revert F1_OwnerNotTimelock(migrator.owner(), cfg.timelock);
        // An EOA "timelock" satisfies the owner check but provides no delay; require a contract.
        if (cfg.timelock.code.length == 0) revert F1_TimelockHasNoCode(cfg.timelock);
        if (migrator.merkleRoot() == bytes32(0)) revert GoLive_RootNotSet();
        uint256 deadline = migrator.CLAIM_DEADLINE();
        if (block.timestamp > deadline) {
            revert GoLive_ClaimWindowClosed(deadline, block.timestamp);
        }
        // A stale dry-run env (near-expired window) or a ms-epoch typo (a multi-millennium window)
        // both pass a bare >= now check; require a plausible migration window.
        if (deadline < block.timestamp + 30 days || deadline > block.timestamp + 2 * 365 days) {
            revert GoLive_ClaimWindowImplausible(deadline);
        }

        _assertStakingGov(cfg.stakedBwsTracker, IRewardTrackerIntrospect(cfg.stakedBwsTracker).gov(), cfg.stakingGov);
        _assertStakingGov(cfg.bonusBwsTracker, IRewardTrackerIntrospect(cfg.bonusBwsTracker).gov(), cfg.stakingGov);
        _assertStakingGov(cfg.feeBwsTracker, IRewardTrackerIntrospect(cfg.feeBwsTracker).gov(), cfg.stakingGov);
        _assertStakingGov(cfg.bnBws, IMintableBaseTokenIntrospect(cfg.bnBws).gov(), cfg.stakingGov);
    }

    function _assertStakingGov(
        address target,
        address actualGov,
        address expected
    ) internal pure {
        if (actualGov != expected) revert F1_StakingGovNotExpected(target, actualGov, expected);
    }

    /// @dev A: CCA launch wiring, checked post-launch (runbook step 6). Each sub-config may be left
    ///      unset ONLY for a pre-launch dry run of D-1..D-5/F-1 - run() prints a loud warning for
    ///      anything skipped. A-1..A-4: the auction's launch token is this BWS, its unsold sink is
    ///      the burner (which burns this BWS), and it offered exactly the auction bucket. A-5..A-7:
    ///      the governance one-shots landed - hook committed, registrar renounced, locker wired.
    function _assertCcaWiring(
        Config memory cfg
    ) internal view {
        if (cfg.auction != address(0)) {
            ICcaAuctionIntrospect auction = ICcaAuctionIntrospect(cfg.auction);
            address auctionToken = auction.token();
            if (auctionToken != cfg.bws) revert A1_AuctionTokenMismatch(auctionToken, cfg.bws);
            address recipient = auction.tokensRecipient();
            if (recipient != cfg.burner) revert A2_TokensRecipientNotBurner(recipient, cfg.burner);
            address burnerBws = address(UnsoldBurner(cfg.burner).BWS());
            if (burnerBws != cfg.bws) revert A3_BurnerBwsMismatch(burnerBws, cfg.bws);
            uint256 auctionSupply = auction.totalSupply();
            if (auctionSupply != ArbitrumConfig.CCA_AUCTION_SUPPLY) {
                revert A4_AuctionSupplyUnexpected(auctionSupply, ArbitrumConfig.CCA_AUCTION_SUPPLY);
            }
        }
        if (cfg.lpLocker != address(0)) {
            GovernanceVoter voter = GovernanceVoter(payable(cfg.voter));
            if (!voter.poolHooksSet()) revert A5_PoolHooksNotCommitted();
            LPLocker locker = LPLocker(payable(cfg.lpLocker));
            if (locker.registrar() != address(0)) revert A6_RegistrarNotRenounced(locker.registrar());
            if (
                locker.GOVERNANCE_VOTER() != cfg.voter || locker.CURRENCY0() != address(0)
                    || locker.CURRENCY1() != cfg.bws || locker.POSITION_MANAGER() != voter.V4_POSITION_MANAGER()
            ) revert A7_LockerWiringMismatch();
            // The locker must be the voter's REGISTERED peer: option-3 locks and initializePeers
            // (feeCollector -> depositRevenue routing) both hang off it.
            if (!voter.peersInitialized() || voter.lpLocker() != cfg.lpLocker) {
                revert A8_LockerNotVoterPeer(voter.lpLocker(), cfg.lpLocker);
            }
        }
    }
}

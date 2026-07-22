// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title EthereumConfig
/// @notice Canonical constants for the BMX -> BWLK migration deploy on Ethereum mainnet (chainId 1):
///         Uniswap v4 infra, the Base reference staking addresses, the fixed BWLK supply split, and
///         the BWLK staking RewardTracker reference runtime codehash (for the D-4 go-live
///         byte-match check).
/// @dev    Every address was verified live on Ethereum / Base (July 2026): the v4 trio is mutually
///         consistent (UniversalRouter.poolManager() == PositionManager.poolManager() ==
///         POOL_MANAGER), the LBPStrategy's initializerFactory/positionManager/poolManager match the
///         constants below, and the three Base RewardTrackers share the reference codehash. Deploy
///         scripts read these as defaults via `vm.envOr`, so any value can be overridden at deploy
///         time without editing this file.
library EthereumConfig {
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;

    // --- Ethereum mainnet Uniswap v4 + WETH (verified) ---
    address internal constant ETH_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ETH_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address internal constant ETH_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address internal constant ETH_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    // --- Legacy BMX (the token surrendered during migration) ---
    // No default: the Ethereum-side migration plan (which chain's BMX is surrendered, whether it is
    // consolidated here first) is being re-scoped after the move from Arbitrum. Scripts 03/04 take
    // BMX_ADDRESS as a required env until that lands.

    // --- Base reference staking stack (the live GMX-style trackers being mirrored on Ethereum) ---
    address internal constant BASE_BMX = 0x548f93779fBC992010C07467cBaf329DD5F059B7;
    address internal constant BASE_STAKED_BMX_TRACKER = 0x3085F25Cbb5F34531229077BAAC20B9ef2AE85CB;
    address internal constant BASE_BONUS_BMX_TRACKER = 0x9A8f034Df900E58C55764fAAC867c5BA11A8F70f;
    address internal constant BASE_FEE_BMX_TRACKER = 0x38E5be3501687500E6338217276069d16178077E; // sbfBMX
    address internal constant BASE_BN_BMX = 0x10AB197551BAB91f8B218dC9730AE0e43d893Db2;

    /// @notice keccak256(runtimeCode) of a BWLK staking `RewardTracker` (solc 0.6.12). All three live
    ///         Base trackers share this hash. `RewardTracker` has no immutables, so a faithful
    ///         redeploy of the same artifact must produce the same runtime codehash (D-4 byte-match).
    /// @dev    Valid ONLY when the Ethereum trackers are compiled from the identical source + solc +
    ///         optimizer + metadata config. The morphex-contracts repo as currently checked in
    ///         produces stripped-byte-identical code with a DIFFERENT metadata hash - pass
    ///         EXPECTED_TRACKER_CODEHASH computed from the actual deploy to the assertion script.
    bytes32 internal constant REFERENCE_REWARD_TRACKER_CODEHASH =
        0x62c7ceea91af37a2953e51017f4e058b86013082f25351da1ae9f9ddc6caeb09;

    /// @notice keccak256(runtimeCode) of the Base bnBMX `MintableBaseToken` (solc 0.6.12), the
    ///         reference for the Ethereum bnBWLK multiplier-point token.
    bytes32 internal constant REFERENCE_MINTABLE_BASE_TOKEN_CODEHASH =
        0xbabfd9e2fd59919640cdfa87e40fb5f9698b278c122372d3c189db27158e384a;

    // --- Fixed BWLK supply split (1e18 units) ---
    uint256 internal constant TOTAL_SUPPLY = 3_150_000e18;
    /// @notice Pre-funded migration pool ("BMX supply, 1:1", 86.07%). Reconciliation vs the
    ///         ~3,041,989 raw summed BMX totalSupply: the Base oBMX contract (0x3Ff7AB26...79713)
    ///         holds ~272k permanently locked protocol BMX that can never reach `migrate()`; net of
    ///         it (and dead/zero) the migratable supply matches this pool (snapshot validate check
    ///         (c) computes the live figure). The D-1 gate takes the reconciled TOTAL_MIGRATABLE_BMX
    ///         env and FAILS until the pool covers it.
    uint256 internal constant MIGRATION_POOL = 2_711_068e18;
    /// @notice Market-formation bucket (10%): 157,500 CCA sale + 157,500 LP seed.
    uint256 internal constant CCA_BUCKET = 315_000e18;
    /// @notice The sale half of CCA_BUCKET (the other 157,500 is the LP seed reserved via
    ///         MigratorParameters.reservedTokenAmountForLP and paired with 100% of the ETH raised).
    uint256 internal constant CCA_AUCTION_SUPPLY = 157_500e18;
    /// @notice LP incentives (3.93%), distributed across one year. Not part of the CCA launch;
    ///         stays in the genesis escrow until the incentives program is wired.
    uint256 internal constant LP_INCENTIVES = 123_932e18;

    /// @notice One-time voter-point credit applied on-chain by `BwlkMigration` (16%). Mirrors
    ///         `BwlkMigration.CREDIT_BPS`; here for deploy-script cross-checks only.
    uint256 internal constant VOTER_CREDIT_BPS = 1_600;

    /// @notice Default migration claim window end: January 20 2027, 11:00 PST (19:00:00 UTC).
    ///         `migrate` is possible at or before this timestamp, `sweepUnclaimed` only after.
    ///         Script 03 reads it as the CLAIM_DEADLINE env default.
    uint256 internal constant MIGRATION_CLAIM_DEADLINE = 1_800_471_600;

    // --- v4 pool config for the BWLK/ETH pool ---
    uint24 internal constant POOL_FEE = 10_000;
    int24 internal constant POOL_TICK_SPACING = 200;

    // --- BWLK CCA launch parameters ---
    // Auction window: July 16 2026 19:00 UTC (12:00 PT) -> July 19 2026 19:00 UTC, exactly 3 days
    // (~21,500 mainnet blocks at the measured ~12.05s effective cadence). The start/end blocks are
    // pinned close to launch; claim and migration blocks default to endBlock + 1 (per Uniswap's
    // guidance) and the step schedule to the convex uniswap-cca shape, both derived in
    // 06_LaunchBwlkCca.s.sol. There is NO graduation threshold for this launch (any raise
    // graduates): the script's default is 0 and the launch command must attest it via
    // CCA_ZERO_GRADUATION_ATTESTED=true.

    /// @notice Bid tick spacing: 1% of the floor price, so the floor sits on exactly the 100th
    ///         tick. Same floor:tick ratio as Uniswap's reference launch.
    uint256 internal constant CCA_TICK_SPACING_Q96 = 127_038_107_261_363_363_806_277;
    /// @notice Auction floor: the announced $0.30 per BWLK, pinned in ETH terms on launch day at
    ///         the Chainlink ETH/USD read of $1,870.97 (2026-07-16) = 0.0001603446 ETH per BWLK as
    ///         a Q96 wei-per-wei price. ETH drift during the auction moves the effective USD floor.
    uint256 internal constant CCA_FLOOR_PRICE_Q96 = CCA_TICK_SPACING_Q96 * 100;

    // The CCA launch runs through the LiquidityLauncher (06_LaunchBwlkCca.s.sol), which sets
    // tokensRecipient = UnsoldBurner and requiredCurrencyRaised at auction creation. Deploy
    // UnsoldBurner via 05_DeployUnsoldBurner.s.sol before the auction. Launcher/strategy are the
    // v3.1.0 mainnet deployments from Uniswap's README; the factory is the strategy's own
    // initializerFactory() (all three verified to have code and mutually consistent wiring).
    address internal constant ETH_CCA_FACTORY = 0x000000001F26a0044BaA66024e7b6599c61963F8;
    address internal constant ETH_LIQUIDITY_LAUNCHER = 0x00004c4ccc709Ef590F7C81102C0689F0263D4e9;
    address internal constant ETH_LBP_STRATEGY = 0x49380c4EfaB1b491006aF7FabAB8B3459F0E6000;
}

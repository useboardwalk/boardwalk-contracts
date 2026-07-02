// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ArbitrumConfig
/// @notice Canonical constants for the BMX -> BWS migration deploy on Arbitrum One (chainId 42161):
///         Uniswap v4 infra, the legacy BMX token, the Base reference staking addresses, the fixed
///         BWS supply split, and the BWS staking RewardTracker reference runtime codehash (for the D-4
///         go-live byte-match check).
/// @dev    Every address was byte-verified live on Arbitrum / Base (June 2026): the v4 trio is
///         mutually consistent (UniversalRouter.poolManager() == PositionManager.poolManager() ==
///         POOL_MANAGER) and the three Base RewardTrackers share the reference codehash below.
///         Deploy scripts read these as defaults via `vm.envOr`, so any value can be overridden at
///         deploy time without editing this file.
library ArbitrumConfig {
    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;

    // --- Arbitrum One Uniswap v4 + WETH (byte-verified) ---
    address internal constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant ARB_UNIVERSAL_ROUTER = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;
    address internal constant ARB_POSITION_MANAGER = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;
    address internal constant ARB_POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

    // --- Legacy BMX (the token surrendered during migration) ---
    address internal constant ARB_BMX = 0xc2694A5C9f3a886D0467FcE5E07f6211dfc86C48;

    // --- Base reference staking stack (the live GMX-style trackers being mirrored on Arbitrum) ---
    address internal constant BASE_BMX = 0x548f93779fBC992010C07467cBaf329DD5F059B7;
    address internal constant BASE_STAKED_BMX_TRACKER = 0x3085F25Cbb5F34531229077BAAC20B9ef2AE85CB;
    address internal constant BASE_BONUS_BMX_TRACKER = 0x9A8f034Df900E58C55764fAAC867c5BA11A8F70f;
    address internal constant BASE_FEE_BMX_TRACKER = 0x38E5be3501687500E6338217276069d16178077E; // sbfBMX
    address internal constant BASE_BN_BMX = 0x10AB197551BAB91f8B218dC9730AE0e43d893Db2;

    /// @notice keccak256(runtimeCode) of a BWS staking `RewardTracker` (solc 0.6.12). All three live Base
    ///         trackers share this hash. `RewardTracker` has no immutables, so a faithful Arbitrum
    ///         redeploy of the same artifact must produce the same runtime codehash (D-4 byte-match).
    /// @dev    Valid ONLY when the Arbitrum trackers are compiled from the identical source + solc +
    ///         optimizer + metadata config. If the Arbitrum build uses a different metadata hash this
    ///         value differs; pass the real Arbitrum codehash via env to the assertion script.
    bytes32 internal constant REFERENCE_REWARD_TRACKER_CODEHASH =
        0x62c7ceea91af37a2953e51017f4e058b86013082f25351da1ae9f9ddc6caeb09;

    /// @notice keccak256(runtimeCode) of the Base bnBMX `MintableBaseToken` (solc 0.6.12), the
    ///         reference for the Arbitrum bnBWS multiplier-point token.
    bytes32 internal constant REFERENCE_MINTABLE_BASE_TOKEN_CODEHASH =
        0xbabfd9e2fd59919640cdfa87e40fb5f9698b278c122372d3c189db27158e384a;

    // --- Fixed BWS supply split (1e18 units) ---
    uint256 internal constant TOTAL_SUPPLY = 3_150_000e18;
    /// @notice Pre-funded migration pool ("BMX supply, 1:1"). Reconciliation vs the ~3,041,989 raw
    ///         summed BMX totalSupply: the Base oBMX contract (0x3Ff7AB26...79713) holds ~272k
    ///         permanently locked protocol BMX that can never reach `migrate()`; net of it (and
    ///         dead/zero) the migratable supply matches this pool (snapshot validate check (c)
    ///         computes the live figure). The D-1 gate takes the reconciled TOTAL_MIGRATABLE_BMX env
    ///         and FAILS until the pool covers it.
    uint256 internal constant MIGRATION_POOL = 2_711_068e18;
    /// @notice Market-formation bucket: 219,466 CCA auction + 219,466 LP seed.
    uint256 internal constant CCA_BUCKET = 438_932e18;
    /// @notice The auction half of CCA_BUCKET (the other 219,466 is the LP seed reserved via
    ///         MigratorParameters.reservedTokenAmountForLP).
    uint256 internal constant CCA_AUCTION_SUPPLY = 219_466e18;

    /// @notice One-time voter-point credit applied on-chain by `BwsMigration` (16%). Mirrors
    ///         `BwsMigration.CREDIT_BPS`; here for deploy-script cross-checks only.
    uint256 internal constant VOTER_CREDIT_BPS = 1_600;

    // --- v4 pool config for the BWS/ETH pool (must equal the CCA UI fee tier + tick spacing) ---
    uint24 internal constant POOL_FEE = 10_000;
    int24 internal constant POOL_TICK_SPACING = 200;

    // --- BWS CCA launch parameters (announced July 2026) ---
    // Auction window: July 6 2026 15:00 UTC -> July 11 2026 06:59 UTC. The block numbers and the
    // step schedule are NOT defaulted here: they depend on the live L2 block rate and are pinned
    // on launch day (see 06_LaunchBwsCca.s.sol).

    /// @notice Bid tick spacing: 1% of the floor price, so the floor sits on exactly the 100th
    ///         tick. Same floor:tick ratio as Uniswap's reference launch.
    uint256 internal constant CCA_TICK_SPACING_Q96 = (uint256(1) << 96) / 400_000;
    /// @notice Auction floor: 0.00025 ETH per BWS as a Q96 wei-per-wei price (tick-aligned; exact
    ///         to 22 significant digits).
    uint256 internal constant CCA_FLOOR_PRICE_Q96 = CCA_TICK_SPACING_Q96 * 100;
    /// @notice Graduation threshold: the full auction supply clearing at the floor (announced as
    ///         54.8665 ETH, floored to the exact wei the tick-aligned floor price can raise - a
    ///         threshold even 1 wei higher would make a complete floor-price sell-out refund).
    uint128 internal constant CCA_REQUIRED_CURRENCY_RAISED = uint128((CCA_AUCTION_SUPPLY * CCA_FLOOR_PRICE_Q96) >> 96);

    // The CCA launch runs through the LiquidityLauncher (06_LaunchBwsCca.s.sol), which sets
    // tokensRecipient = UnsoldBurner and requiredCurrencyRaised at auction creation. Deploy
    // UnsoldBurner via 05_DeployUnsoldBurner.s.sol before the auction. All four addresses below
    // have code on Arbitrum One (checked in test/fork/UnsoldBurnerFork.t.sol).
    address internal constant ARB_CCA_FACTORY = 0x00cCa200BF124dBfA848937c553864f4B4CE0632;
    address internal constant ARB_LIQUIDITY_LAUNCHER = 0x00004c4ccc709Ef590F7C81102C0689F0263D4e9;
    address internal constant ARB_LBP_STRATEGY = 0x18608AD558dcD233F7854242bbAef73988Bee000;
    address internal constant ARB_CCA_LENS = 0xc3C65F5453A3674aDb693cbdA3C842545cD30f53;
}

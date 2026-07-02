// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiquidityLauncher} from "src/interfaces/ILiquidityLauncher.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ICcaAuctionFactory} from "src/interfaces/ICcaAuctionFactory.sol";
import {IPermit2} from "src/interfaces/IPermit2.sol";
import {UnsoldBurner} from "src/token/UnsoldBurner.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {ArbitrumConfig} from "./ArbitrumConfig.sol";

/// @dev CCA auction getters the post-launch verification reads (ContinuousClearingAuction).
interface ICcaAuctionIntrospect {
    function token() external view returns (address);
    function currency() external view returns (address);
    function tokensRecipient() external view returns (address);
    function fundsRecipient() external view returns (address);
    function totalSupply() external view returns (uint128);
}

/// @title LaunchBwsCca - Launch the 438,932 BWS market-formation bucket through Uniswap's CCA
/// @notice From the wallet holding the bucket, deposit + distribute through the LiquidityLauncher
///         so the LBPStrategy creates and registers the auction (auction half = 219,466 BWS; the
///         other 219,466 is the LP reserve).
/// @dev    Deposit and distribute are batched in one `multicall` tx: the launcher keeps no
///         per-depositor accounting, so tokens parked between separate txs could be distributed by
///         anyone. Funding moves via Permit2 (ERC20 approve to Permit2 + a Permit2 allowance for
///         the launcher), sized exactly so both allowances are consumed to zero by the deposit.
///
///         Required env: DEPLOYER_PRIVATE_KEY (the bucket wallet), BWS_TOKEN, GOVERNANCE_VOTER,
///         LP_LOCKER, UNSOLD_BURNER, LAUNCH_RECIPIENT (treasury: leftovers + the whole LP seed on
///         non-graduation), CCA_START_BLOCK / CCA_END_BLOCK / CCA_CLAIM_BLOCK / CCA_MIGRATION_BLOCK
///         (ArbSys L2 block numbers), CCA_TICK_SPACING_Q96 / CCA_FLOOR_PRICE_Q96 (Q96 currency-per-
///         token prices: wei-per-wei ratio << 96), CCA_REQUIRED_CURRENCY_RAISED (graduation
///         threshold in wei; 0 needs CCA_ZERO_GRADUATION_ATTESTED=true), CCA_AUCTION_STEPS (packed
///         hex, 8 bytes per step: uint24 mps + uint40 blockDelta; mps*delta must sum to 1e7 and the
///         deltas must span exactly start..end). Optional: CCA_LIQUIDITY_LAUNCHER / CCA_LBP_STRATEGY
///         (default ArbitrumConfig), CCA_LAUNCH_SALT (default 0).
contract LaunchBwsCca is Script {
    using SafeERC20 for IERC20;

    /// @dev mps denominator (1e7 = 100%), shared by auction steps, position weights, LP brackets.
    uint24 internal constant MPS = 1e7;
    /// @dev Packed auction-step width: uint24 mps + uint40 blockDelta.
    uint256 internal constant STEP_BYTES = 8;
    /// @dev v4 TickMath bounds; the (MIN_TICK, MAX_TICK) offset pair is the planner's full-range sentinel.
    int24 internal constant MIN_TICK = -887_272;
    int24 internal constant MAX_TICK = 887_272;
    /// @dev The LP-reserve half of the bucket (the auction offers the rest).
    uint128 internal constant LP_RESERVE = uint128(ArbitrumConfig.CCA_BUCKET - ArbitrumConfig.CCA_AUCTION_SUPPLY);
    /// @dev The CCA TickStorage constructor's lower price bounds (ConstantsLib.MIN_TICK_SPACING /
    ///      MIN_FLOOR_PRICE).
    uint256 internal constant MIN_TICK_SPACING_Q96 = 2;
    uint256 internal constant MIN_FLOOR_PRICE_Q96 = (uint256(1) << 32) + 1;
    /// @dev Arbitrum ArbSys precompile + `arbBlockNumber()` selector (the CCA's block clock).
    address internal constant ARB_SYS = 0x0000000000000000000000000000000000000064;
    bytes4 internal constant ARB_BLOCK_NUMBER_SELECTOR = 0xa3b1b31d;

    struct LaunchConfig {
        address wallet; // holder of the 438,932e18 bucket; the caller of deposit+distribute
        address bws;
        address launcher;
        address strategy;
        address voter;
        address lpLocker; // positionRecipient: every LP position mints here
        address burner; // tokensRecipient: unsold BWS sink
        address recipient; // leftover currency/token dust + the entire LP seed on non-graduation
        uint64 startBlock; // ArbSys L2 block numbers, not block.number
        uint64 endBlock;
        uint64 claimBlock;
        uint64 migrationBlock;
        uint256 tickSpacingQ96;
        uint256 floorPriceQ96;
        uint128 requiredCurrencyRaised;
        bool zeroGraduationAttested;
        bytes auctionStepsData;
        bytes32 salt;
    }

    error WrongChain(uint256 chainId);
    error EnvValueTooLarge(string name, uint256 value);
    error WalletMismatch(address wallet, address expected);
    error BwsHasNoCode(address bws);
    error BwsSupplyWrong(uint256 actual, uint256 expected);
    error WalletBucketMissing(address wallet, uint256 balance, uint256 required);
    error LauncherHasNoCode(address launcher);
    error Permit2HasNoCode(address permit2);
    error StrategyHasNoCode(address strategy);
    error FactoryHasNoCode(address factory);
    error PositionManagerMismatch(address strategyPm, address lockerPm);
    error BurnerHasNoCode(address burner);
    error BurnerBwsMismatch(address burnerBws, address bws);
    error LockerVoterMismatch(address lockerVoter, address voter);
    error LockerCurrenciesWrong(address currency0, address currency1);
    error RegistrarAlreadyRenounced();
    error PoolHooksAlreadySet();
    error VoterPoolParamsUnexpected(uint24 fee, int24 tickSpacing);
    error RecipientInvalid(address recipient);
    error StartBlockNotInFuture(uint64 startBlock, uint256 currentBlock);
    error BlockOrderInvalid(uint64 startBlock, uint64 endBlock, uint64 claimBlock, uint64 migrationBlock);
    error StepDataLengthInvalid(uint256 length);
    error StepBlockDeltaZero(uint256 stepIndex);
    error StepMpsSumWrong(uint256 sumMps);
    error StepSpanMismatch(uint256 calculatedEndBlock, uint64 endBlock);
    error GraduationThresholdZeroUnattested();
    error PriceUnderMinimum(uint256 tickSpacingQ96, uint256 floorPriceQ96);
    error FloorNotAtTickBoundary(uint256 floorPriceQ96, uint256 tickSpacingQ96);
    error PriceOverMaxBid(uint256 tickSpacingQ96, uint256 floorPriceQ96, uint256 maxBidPriceQ96);
    error AuctionAlreadyDeployed(address predicted);
    error AuctionNotDeployed(address predicted);
    error AuctionTokenMismatch(address actual, address expected);
    error AuctionCurrencyNotNative(address actual);
    error AuctionTokensRecipientMismatch(address actual, address expected);
    error AuctionFundsRecipientMismatch(address actual, address expected);
    error AuctionSupplyMismatch(uint256 actual, uint256 expected);
    error InitializerNotRegisteredWithStrategy(address auction);

    function run() external {
        if (block.chainid != ArbitrumConfig.ARBITRUM_CHAIN_ID) revert WrongChain(block.chainid);
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        LaunchConfig memory cfg = _configFromEnv(vm.addr(deployerPrivateKey));

        check(cfg);
        address predicted = predictAuction(cfg);
        if (predicted.code.length != 0) revert AuctionAlreadyDeployed(predicted);

        // A forked simulation cannot execute the ArbSys precompile (its on-chain code is the 0xfe
        // stub), which the CCA constructor calls; mock it to the RPC block number (on Arbitrum
        // eth_blockNumber == arbBlockNumber). Simulation-only - broadcast txs use the real precompile.
        (bool arbSysOk,) = ARB_SYS.staticcall(abi.encodeWithSelector(ARB_BLOCK_NUMBER_SELECTOR));
        if (!arbSysOk) {
            vm.mockCall(ARB_SYS, abi.encodeWithSelector(ARB_BLOCK_NUMBER_SELECTOR), abi.encode(block.number));
        }

        vm.startBroadcast(deployerPrivateKey);
        _execute(cfg);
        vm.stopBroadcast();

        verifyLaunch(cfg, predicted);
        _printRunbook(cfg, predicted);
    }

    /// @notice Test/fork-harness entrypoint: the same check -> execute -> verify path as `run()`,
    ///         called directly with this contract as the bucket wallet (no broadcast, no env).
    function launch(
        LaunchConfig memory cfg
    ) public returns (address auction) {
        // The launcher pulls from msg.sender and salts the initializer with it, so the configured
        // wallet must be the actual caller of deposit+distribute - here, this contract.
        if (cfg.wallet != address(this)) revert WalletMismatch(cfg.wallet, address(this));
        check(cfg);
        auction = predictAuction(cfg);
        if (auction.code.length != 0) revert AuctionAlreadyDeployed(auction);
        _execute(cfg);
        verifyLaunch(cfg, auction);
    }

    /// @notice Reverts unless every pre-broadcast launch invariant holds for `cfg`.
    function check(
        LaunchConfig memory cfg
    ) public view {
        // Token + bucket: the genuine fixed-supply BWS, and the wallet actually holds the bucket.
        if (cfg.bws.code.length == 0) revert BwsHasNoCode(cfg.bws);
        uint256 supply = IERC20(cfg.bws).totalSupply();
        if (supply != ArbitrumConfig.TOTAL_SUPPLY) revert BwsSupplyWrong(supply, ArbitrumConfig.TOTAL_SUPPLY);
        uint256 balance = IERC20(cfg.bws).balanceOf(cfg.wallet);
        if (balance < ArbitrumConfig.CCA_BUCKET) {
            revert WalletBucketMissing(cfg.wallet, balance, ArbitrumConfig.CCA_BUCKET);
        }

        // Uniswap side: launcher, its Permit2, the strategy and its auction factory all have code.
        if (cfg.launcher.code.length == 0) revert LauncherHasNoCode(cfg.launcher);
        address permit2 = ILiquidityLauncher(cfg.launcher).permit2();
        if (permit2.code.length == 0) revert Permit2HasNoCode(permit2);
        if (cfg.strategy.code.length == 0) revert StrategyHasNoCode(cfg.strategy);
        address factory = ILBPStrategy(cfg.strategy).initializerFactory();
        if (factory.code.length == 0) revert FactoryHasNoCode(factory);

        // Unsold sink: the burner's token and the auction's tokensRecipient are both immutable,
        // so a mismatch here strands the unsold supply.
        if (cfg.burner.code.length == 0) revert BurnerHasNoCode(cfg.burner);
        address burnerBws = address(UnsoldBurner(cfg.burner).BWS());
        if (burnerBws != cfg.bws) revert BurnerBwsMismatch(burnerBws, cfg.bws);

        // Locker: the LP positions mint here permanently at migration, so its wiring must already
        // be right and its registrar must still exist to register them afterwards.
        LPLocker locker = LPLocker(payable(cfg.lpLocker));
        if (locker.GOVERNANCE_VOTER() != cfg.voter) revert LockerVoterMismatch(locker.GOVERNANCE_VOTER(), cfg.voter);
        if (locker.CURRENCY0() != address(0) || locker.CURRENCY1() != cfg.bws) {
            revert LockerCurrenciesWrong(locker.CURRENCY0(), locker.CURRENCY1());
        }
        if (locker.registrar() == address(0)) revert RegistrarAlreadyRenounced();
        // The strategy mints through its own position manager; the locker must claim via the same one.
        address strategyPm = ILBPStrategy(cfg.strategy).positionManager();
        if (strategyPm != locker.POSITION_MANAGER()) {
            revert PositionManagerMismatch(strategyPm, locker.POSITION_MANAGER());
        }

        // Voter: the hook is only committed after migrate; already set means the order broke.
        // Fee/tick are read from the voter when building MigratorParameters - cross-check them
        // against the canonical config so a mis-deployed voter cannot steer the launch.
        GovernanceVoter voter = GovernanceVoter(payable(cfg.voter));
        if (voter.poolHooksSet()) revert PoolHooksAlreadySet();
        if (
            voter.POOL_FEE() != ArbitrumConfig.POOL_FEE || voter.POOL_TICK_SPACING() != ArbitrumConfig.POOL_TICK_SPACING
        ) {
            revert VoterPoolParamsUnexpected(voter.POOL_FEE(), voter.POOL_TICK_SPACING());
        }

        // Recipient: gets leftovers plus the entire LP seed back on non-graduation. address(1)/(2)
        // are PositionManager sentinels upstream rejects for positions; refuse them here too.
        if (cfg.recipient == address(0) || uint160(cfg.recipient) <= 2) revert RecipientInvalid(cfg.recipient);

        // Block ordering. block.number on an Arbitrum RPC is the L2 height (== arbBlockNumber), so
        // the in-future check is meaningful at simulation time; leave margin for broadcast delay.
        if (cfg.startBlock <= block.number) revert StartBlockNotInFuture(cfg.startBlock, block.number);
        if (cfg.startBlock >= cfg.endBlock || cfg.claimBlock < cfg.endBlock || cfg.migrationBlock <= cfg.endBlock) {
            revert BlockOrderInvalid(cfg.startBlock, cfg.endBlock, cfg.claimBlock, cfg.migrationBlock);
        }

        _checkSteps(cfg);

        // A zero threshold graduates on any raise; require an explicit attestation to allow it.
        if (cfg.requiredCurrencyRaised == 0 && !cfg.zeroGraduationAttested) {
            revert GraduationThresholdZeroUnattested();
        }

        // The CCA constructor's price bounds, replicated so a typo'd Q96 value (typically a
        // forgotten << 96) fails here instead of in the broadcast. Lower bounds and the
        // floor-on-a-tick-boundary rule mirror TickStorage; the upper bound mirrors MaxBidPriceLib.
        // Minimums first, so the modulo cannot divide by zero.
        if (cfg.tickSpacingQ96 < MIN_TICK_SPACING_Q96 || cfg.floorPriceQ96 < MIN_FLOOR_PRICE_Q96) {
            revert PriceUnderMinimum(cfg.tickSpacingQ96, cfg.floorPriceQ96);
        }
        if (cfg.floorPriceQ96 % cfg.tickSpacingQ96 != 0) {
            revert FloorNotAtTickBoundary(cfg.floorPriceQ96, cfg.tickSpacingQ96);
        }
        uint256 maxBid = _maxBidPrice();
        if (cfg.tickSpacingQ96 > maxBid || cfg.floorPriceQ96 > maxBid - cfg.tickSpacingQ96) {
            revert PriceOverMaxBid(cfg.tickSpacingQ96, cfg.floorPriceQ96, maxBid);
        }
    }

    /// @notice The auction constructor parameters this launch commits to (all immutable once created).
    function buildAuctionParameters(
        LaunchConfig memory cfg
    ) public pure returns (ICcaAuctionFactory.AuctionParameters memory) {
        return ICcaAuctionFactory.AuctionParameters({
            currency: address(0), // native ETH raise
            tokensRecipient: cfg.burner,
            fundsRecipient: cfg.strategy, // required: the strategy sweeps the raise at migrate()
            startBlock: cfg.startBlock,
            endBlock: cfg.endBlock,
            claimBlock: cfg.claimBlock,
            tickSpacing: cfg.tickSpacingQ96,
            validationHook: address(0),
            floorPrice: cfg.floorPriceQ96,
            requiredCurrencyRaised: cfg.requiredCurrencyRaised,
            auctionStepsData: cfg.auctionStepsData
        });
    }

    /// @notice The migration parameters this launch commits to. One full-range position (the
    ///         planner's MIN/MAX sentinel) minted to the locker, 100% of the raise as LP budget,
    ///         excess on either side swept to `recipient` - the reference-launch configuration.
    function buildMigratorParameters(
        LaunchConfig memory cfg
    ) public view returns (ILBPStrategy.MigratorParameters memory) {
        ILBPStrategy.PositionDefinition[] memory defs = new ILBPStrategy.PositionDefinition[](1);
        defs[0] = ILBPStrategy.PositionDefinition({
            offsetLower: MIN_TICK,
            offsetUpper: MAX_TICK,
            weight: MPS,
            overridePositionRecipient: address(0) // default recipient = positionRecipient = the locker
        });
        ILBPStrategy.LiquidityAllocationBracket[] memory brackets = new ILBPStrategy.LiquidityAllocationBracket[](1);
        brackets[0] = ILBPStrategy.LiquidityAllocationBracket({lowerThreshold: 0, rate: MPS});

        GovernanceVoter voter = GovernanceVoter(payable(cfg.voter));
        return ILBPStrategy.MigratorParameters({
            token: cfg.bws,
            currency: address(0),
            migrationBlock: cfg.migrationBlock,
            reservedTokenAmountForLP: LP_RESERVE,
            recipient: cfg.recipient,
            positionRecipient: cfg.lpLocker,
            // Read live from the voter: options 2/3/4 trade through the pool key built from these
            // immutables, so a divergent launch would strand governance on a nonexistent pool.
            poolParameters: ILBPStrategy.PoolParameters({
                fee: voter.POOL_FEE(),
                tickSpacing: voter.POOL_TICK_SPACING(),
                hook: address(0) // hookless; the actual hook is read back post-migrate and committed via setPoolHooks
            }),
            positionDefinitions: abi.encode(defs),
            lpAllocationSchedule: abi.encode(brackets)
        });
    }

    /// @notice The full `Distribution.configData`: abi.encode(MigratorParameters, abi.encode(AuctionParameters)).
    function buildConfigData(
        LaunchConfig memory cfg
    ) public view returns (bytes memory) {
        return abi.encode(buildMigratorParameters(cfg), abi.encode(buildAuctionParameters(cfg)));
    }

    /// @notice Predicts the auction (initializer) address the strategy will deploy, replicating the
    ///         launcher's salt derivation: launcher passes keccak256(wallet, salt); the strategy
    ///         salts the factory with keccak256(that, migrationParams); the factory CREATE2s with
    ///         keccak256(strategy, that).
    function predictAuction(
        LaunchConfig memory cfg
    ) public view returns (address) {
        bytes32 initializerSalt =
            keccak256(abi.encode(keccak256(abi.encode(cfg.wallet, cfg.salt)), buildMigratorParameters(cfg)));
        address factory = ILBPStrategy(cfg.strategy).initializerFactory();
        return ICcaAuctionFactory(factory)
            .getAddress(
                cfg.bws,
                ArbitrumConfig.CCA_AUCTION_SUPPLY, // distributed bucket minus the LP reserve
                abi.encode(buildAuctionParameters(cfg)),
                initializerSalt,
                cfg.strategy
            );
    }

    /// @notice Reverts unless the launch actually produced the predicted, correctly-wired,
    ///         strategy-registered auction. In `run()` this executes on the post-broadcast
    ///         simulation state, so a mis-encoding aborts before anything is sent.
    function verifyLaunch(
        LaunchConfig memory cfg,
        address predicted
    ) public view {
        if (predicted.code.length == 0) revert AuctionNotDeployed(predicted);
        ICcaAuctionIntrospect auction = ICcaAuctionIntrospect(predicted);
        if (auction.token() != cfg.bws) revert AuctionTokenMismatch(auction.token(), cfg.bws);
        if (auction.currency() != address(0)) revert AuctionCurrencyNotNative(auction.currency());
        if (auction.tokensRecipient() != cfg.burner) {
            revert AuctionTokensRecipientMismatch(auction.tokensRecipient(), cfg.burner);
        }
        if (auction.fundsRecipient() != cfg.strategy) {
            revert AuctionFundsRecipientMismatch(auction.fundsRecipient(), cfg.strategy);
        }
        if (auction.totalSupply() != ArbitrumConfig.CCA_AUCTION_SUPPLY) {
            revert AuctionSupplyMismatch(auction.totalSupply(), ArbitrumConfig.CCA_AUCTION_SUPPLY);
        }
        // Registered with the strategy; an auction it never registered cannot be migrated.
        if (ILBPStrategy(cfg.strategy).initializers(predicted).migrationBlock != cfg.migrationBlock) {
            revert InitializerNotRegisteredWithStrategy(predicted);
        }
    }

    /// @dev Funds and creates in one atomic multicall (see contract NatSpec). Both approvals are
    ///      exact-sized and consumed to zero by the deposit.
    function _execute(
        LaunchConfig memory cfg
    ) internal {
        address permit2 = ILiquidityLauncher(cfg.launcher).permit2();
        IERC20(cfg.bws).forceApprove(permit2, ArbitrumConfig.CCA_BUCKET);
        IPermit2(permit2)
            .approve(cfg.bws, cfg.launcher, uint160(ArbitrumConfig.CCA_BUCKET), uint48(block.timestamp + 1 days));

        ILiquidityLauncher.Distribution memory distribution = ILiquidityLauncher.Distribution({
            strategy: cfg.strategy, amount: uint128(ArbitrumConfig.CCA_BUCKET), configData: buildConfigData(cfg)
        });
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ILiquidityLauncher.depositToken, (cfg.bws, uint160(ArbitrumConfig.CCA_BUCKET)));
        calls[1] = abi.encodeCall(ILiquidityLauncher.distributeToken, (cfg.bws, distribution, cfg.salt));
        ILiquidityLauncher(cfg.launcher).multicall(calls);
    }

    /// @dev Steps encoding check, mirroring StepStorage._validate: 8 bytes per step, no zero
    ///      deltas, mps*delta sums to exactly 1e7, and the deltas span exactly start..end.
    function _checkSteps(
        LaunchConfig memory cfg
    ) internal pure {
        bytes memory steps = cfg.auctionStepsData;
        if (steps.length == 0 || steps.length % STEP_BYTES != 0) revert StepDataLengthInvalid(steps.length);
        uint256 sumMps;
        uint256 sumDelta;
        for (uint256 o = 0; o < steps.length; o += STEP_BYTES) {
            uint256 mps =
                (uint256(uint8(steps[o])) << 16) | (uint256(uint8(steps[o + 1])) << 8) | uint256(uint8(steps[o + 2]));
            uint256 delta = (uint256(uint8(steps[o + 3])) << 32) | (uint256(uint8(steps[o + 4])) << 24)
                | (uint256(uint8(steps[o + 5])) << 16) | (uint256(uint8(steps[o + 6])) << 8)
                | uint256(uint8(steps[o + 7]));
            if (delta == 0) revert StepBlockDeltaZero(o / STEP_BYTES);
            sumMps += mps * delta;
            sumDelta += delta;
        }
        if (sumMps != MPS) revert StepMpsSumWrong(sumMps);
        if (uint256(cfg.startBlock) + sumDelta != cfg.endBlock) {
            revert StepSpanMismatch(uint256(cfg.startBlock) + sumDelta, cfg.endBlock);
        }
    }

    /// @dev MaxBidPriceLib.maxBidPrice for the fixed 219,466e18 auction supply: min of the
    ///      liquidity bound (2^154/supply)^2 and the int128 currency bound 2^222/supply.
    function _maxBidPrice() internal pure returns (uint256) {
        uint256 liquidityBound = ((uint256(1) << 154) / ArbitrumConfig.CCA_AUCTION_SUPPLY) ** 2;
        uint256 currencyBound = (uint256(1) << 222) / ArbitrumConfig.CCA_AUCTION_SUPPLY;
        return liquidityBound < currencyBound ? liquidityBound : currencyBound;
    }

    function _configFromEnv(
        address wallet
    ) internal view returns (LaunchConfig memory cfg) {
        cfg.wallet = wallet;
        cfg.bws = vm.envAddress("BWS_TOKEN");
        cfg.launcher = vm.envOr("CCA_LIQUIDITY_LAUNCHER", ArbitrumConfig.ARB_LIQUIDITY_LAUNCHER);
        cfg.strategy = vm.envOr("CCA_LBP_STRATEGY", ArbitrumConfig.ARB_LBP_STRATEGY);
        cfg.voter = vm.envAddress("GOVERNANCE_VOTER");
        cfg.lpLocker = vm.envAddress("LP_LOCKER");
        cfg.burner = vm.envAddress("UNSOLD_BURNER");
        cfg.recipient = vm.envAddress("LAUNCH_RECIPIENT");
        cfg.startBlock = _envU64("CCA_START_BLOCK");
        cfg.endBlock = _envU64("CCA_END_BLOCK");
        cfg.claimBlock = _envU64("CCA_CLAIM_BLOCK");
        cfg.migrationBlock = _envU64("CCA_MIGRATION_BLOCK");
        cfg.tickSpacingQ96 = vm.envUint("CCA_TICK_SPACING_Q96");
        cfg.floorPriceQ96 = vm.envUint("CCA_FLOOR_PRICE_Q96");
        cfg.requiredCurrencyRaised = _envU128("CCA_REQUIRED_CURRENCY_RAISED");
        cfg.zeroGraduationAttested = vm.envOr("CCA_ZERO_GRADUATION_ATTESTED", false);
        cfg.auctionStepsData = vm.envBytes("CCA_AUCTION_STEPS");
        cfg.salt = vm.envOr("CCA_LAUNCH_SALT", bytes32(0));
    }

    function _envU64(
        string memory name
    ) internal view returns (uint64) {
        uint256 v = vm.envUint(name);
        if (v > type(uint64).max) revert EnvValueTooLarge(name, v);
        return uint64(v);
    }

    function _envU128(
        string memory name
    ) internal view returns (uint128) {
        uint256 v = vm.envUint(name);
        if (v > type(uint128).max) revert EnvValueTooLarge(name, v);
        return uint128(v);
    }

    function _printRunbook(
        LaunchConfig memory cfg,
        address auction
    ) internal pure {
        console.log("BWS CCA launch submitted through the LiquidityLauncher.");
        console.log("");
        console.log("CCA auction (initializer):", auction);
        console.log("Record this address; every step below needs it.");
        console.log("  offered supply:", ArbitrumConfig.CCA_AUCTION_SUPPLY / 1e18, "BWS");
        console.log("  LP reserve    :", uint256(LP_RESERVE) / 1e18, "BWS (held by the strategy until migrate)");
        console.log("  endBlock      :", cfg.endBlock);
        console.log("  migrationBlock:", cfg.migrationBlock);
        console.log("");
        console.log("After the auction ends (post-endBlock, post-migrationBlock; ArbSys L2 blocks):");
        console.log("1. Call LBPStrategy.migrate(initializer) - permissionless and not automated,");
        console.log("   schedule it. No pool, LP, or Migrated event exists until this lands.");
        console.log("2. Recover the pool hook from the migrate tx: the Migrated event's key topic is only");
        console.log("   a hash - read the hook from the same tx's PoolManager Initialize event (or");
        console.log("   getPoolAndPositionInfo on a minted tokenId), verify keccak256(abi.encode(key))");
        console.log("   matches the Migrated topic, then GovernanceVoter.setPoolHooks(hook) - one-shot.");
        console.log("   Expect address(0), or the LBPStrategy address if the hookless pool was front-run.");
        console.log("3. Register every PositionManager Transfer(0x0 -> LPLocker) tokenId via");
        console.log("   LPLocker.registerPosition(tokenId), confirm getLockedPositions(), then");
        console.log("   renounceRegistrar(). An unregistered position's fees are stranded forever.");
        console.log("4. After endBlock anyone can call UnsoldBurner.sweep(auction) to burn unsold BWS.");
        console.log("5. Re-run the go-live gate with the launch wiring:");
        console.log("   STAKING_GOV=... CCA_AUCTION=<auction above> UNSOLD_BURNER=... LP_LOCKER=... \\");
        console.log("     forge script script/bws/04_AssertBwsDeploy.s.sol --rpc-url $ARB_RPC");
    }
}

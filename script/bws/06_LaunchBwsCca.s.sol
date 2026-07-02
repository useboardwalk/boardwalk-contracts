// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ILiquidityLauncher} from "src/interfaces/ILiquidityLauncher.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ICcaAuctionFactory} from "src/interfaces/ICcaAuctionFactory.sol";
import {IPermit2} from "src/interfaces/IPermit2.sol";
import {UnsoldBurner} from "src/token/UnsoldBurner.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {ArbitrumConfig} from "./ArbitrumConfig.sol";

/// @dev The one auction getter the post-launch verification reads.
interface ICcaAuctionIntrospect {
    function tokensRecipient() external view returns (address);
}

/// @title LaunchBwsCca - Launch the 438,932 BWS market-formation bucket through Uniswap's CCA
/// @notice From the wallet holding the bucket, deposit + distribute through the LiquidityLauncher
///         so the LBPStrategy creates and registers the auction (auction half = 219,466 BWS; the
///         other 219,466 is the LP reserve).
/// @dev    `check()` covers only what the Uniswap contracts don't enforce themselves; the auction
///         parameters (step schedule, price bounds, block ordering) are validated by the CCA
///         constructor during forge's pre-broadcast simulation, which reverts atomically.
///
/// Required env vars:
/// - DEPLOYER_PRIVATE_KEY: bucket wallet
/// - BWS_TOKEN
/// - GOVERNANCE_VOTER
/// - LP_LOCKER
/// - UNSOLD_BURNER
/// - LAUNCH_RECIPIENT: treasury (leftovers + entire LP seed on non-graduation)
/// - CCA_START_BLOCK (ArbSys L2 block num)
/// - CCA_END_BLOCK (ArbSys L2 block num)
/// - CCA_CLAIM_BLOCK (ArbSys L2 block num)
/// - CCA_MIGRATION_BLOCK (ArbSys L2 block num)
/// - CCA_AUCTION_STEPS: packed hex, 8 bytes/step (uint24 mps + uint40 blockDelta; mps*delta = 1e7, deltas span start..end)
/// Optional (defaults are the announced launch values / canonical addresses in ArbitrumConfig):
/// - CCA_TICK_SPACING_Q96: Q96 token price (default: 1% of the floor)
/// - CCA_FLOOR_PRICE_Q96: Q96 token price (default: 0.00025 ETH per BWS)
/// - CCA_REQUIRED_CURRENCY_RAISED: graduation threshold in wei (default: full supply clearing at
///   the floor, ~54.8665 ETH; 0 needs CCA_ZERO_GRADUATION_ATTESTED=true)
/// - CCA_LIQUIDITY_LAUNCHER (default: ArbitrumConfig)
/// - CCA_LBP_STRATEGY (default: ArbitrumConfig)
/// - CCA_LAUNCH_SALT (default: 0)
contract LaunchBwsCca is Script {
    using SafeERC20 for IERC20;

    /// @dev mps denominator (1e7 = 100%), shared by position weights and LP brackets.
    uint24 internal constant MPS = 1e7;
    /// @dev The LP-reserve half of the bucket (the auction offers the rest).
    uint128 internal constant LP_RESERVE = uint128(ArbitrumConfig.CCA_BUCKET - ArbitrumConfig.CCA_AUCTION_SUPPLY);
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
    error WalletBucketMissing(address wallet, uint256 balance, uint256 required);
    error BurnerBwsMismatch(address burnerBws, address bws);
    error LockerVoterMismatch(address lockerVoter, address voter);
    error LockerCurrenciesWrong(address currency0, address currency1);
    error RegistrarAlreadyRenounced();
    error PositionManagerMismatch(address strategyPm, address lockerPm);
    error PoolHooksAlreadySet();
    error StartBlockNotInFuture(uint64 startBlock, uint256 currentBlock);
    error GraduationThresholdZeroUnattested();
    error AuctionNotDeployed(address predicted);
    error AuctionTokensRecipientMismatch(address actual, address expected);
    error InitializerNotRegisteredWithStrategy(address auction);

    function run() external {
        if (block.chainid != ArbitrumConfig.ARBITRUM_CHAIN_ID) revert WrongChain(block.chainid);
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        LaunchConfig memory cfg = _configFromEnv(vm.addr(deployerPrivateKey));
        check(cfg);
        address predicted = predictAuction(cfg);

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
        _execute(cfg);
        verifyLaunch(cfg, auction);
    }

    /// @notice Wiring invariants the Uniswap contracts cannot check for us.
    function check(
        LaunchConfig memory cfg
    ) public view {
        // The wallet holds the bucket.
        uint256 balance = IERC20(cfg.bws).balanceOf(cfg.wallet);
        if (balance < ArbitrumConfig.CCA_BUCKET) {
            revert WalletBucketMissing(cfg.wallet, balance, ArbitrumConfig.CCA_BUCKET);
        }

        // The burner's token and the auction's tokensRecipient are both immutable; a mismatch
        // strands the unsold supply.
        address burnerBws = address(UnsoldBurner(cfg.burner).BWS());
        if (burnerBws != cfg.bws) revert BurnerBwsMismatch(burnerBws, cfg.bws);

        // The LP positions mint to the locker permanently at migration: its wiring must be right,
        // its registrar must still exist to register them afterwards, and it must claim through
        // the same position manager the strategy mints on.
        LPLocker locker = LPLocker(payable(cfg.lpLocker));
        if (locker.GOVERNANCE_VOTER() != cfg.voter) revert LockerVoterMismatch(locker.GOVERNANCE_VOTER(), cfg.voter);
        if (locker.CURRENCY0() != address(0) || locker.CURRENCY1() != cfg.bws) {
            revert LockerCurrenciesWrong(locker.CURRENCY0(), locker.CURRENCY1());
        }
        if (locker.registrar() == address(0)) revert RegistrarAlreadyRenounced();
        address strategyPm = ILBPStrategy(cfg.strategy).positionManager();
        if (strategyPm != locker.POSITION_MANAGER()) {
            revert PositionManagerMismatch(strategyPm, locker.POSITION_MANAGER());
        }

        // The hook is only committed after migrate; already set means the order broke.
        if (GovernanceVoter(payable(cfg.voter)).poolHooksSet()) revert PoolHooksAlreadySet();

        // The CCA accepts a startBlock in the past and silently skips the elapsed schedule.
        // block.number on an Arbitrum RPC is the L2 height; leave margin for broadcast delay.
        if (cfg.startBlock <= block.number) revert StartBlockNotInFuture(cfg.startBlock, block.number);

        // A zero threshold graduates on any raise; require an explicit attestation to allow it.
        if (cfg.requiredCurrencyRaised == 0 && !cfg.zeroGraduationAttested) {
            revert GraduationThresholdZeroUnattested();
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

    /// @notice The migration parameters this launch commits to: one full-range position (the
    ///         planner's MIN/MAX sentinel) minted to the locker, 100% of the raise as LP budget,
    ///         excess on either side swept to `recipient`.
    function buildMigratorParameters(
        LaunchConfig memory cfg
    ) public view returns (ILBPStrategy.MigratorParameters memory) {
        // The (MIN_TICK, MAX_TICK) offset pair is the position planner's full-range sentinel.
        ILBPStrategy.PositionDefinition[] memory defs = new ILBPStrategy.PositionDefinition[](1);
        defs[0] = ILBPStrategy.PositionDefinition({
            offsetLower: TickMath.MIN_TICK,
            offsetUpper: TickMath.MAX_TICK,
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
            poolParameters: ILBPStrategy.PoolParameters({
                fee: voter.POOL_FEE(),
                tickSpacing: voter.POOL_TICK_SPACING(),
                hook: address(0) // hookless; the actual hook is read back post-migrate and committed via setPoolHooks
            }),
            positionDefinitions: abi.encode(defs),
            lpAllocationSchedule: abi.encode(brackets)
        });
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

    /// @notice Post-simulation check that the launch produced the predicted auction. The strategy
    ///         already validates token, currency and fundsRecipient at creation; what's left is
    ///         that the prediction matched (ops acts on the printed address), the auction is
    ///         registered so migrate() can run, and the unsold supply drains to the burner.
    function verifyLaunch(
        LaunchConfig memory cfg,
        address predicted
    ) public view {
        if (predicted.code.length == 0) revert AuctionNotDeployed(predicted);
        address tokensRecipient = ICcaAuctionIntrospect(predicted).tokensRecipient();
        if (tokensRecipient != cfg.burner) revert AuctionTokensRecipientMismatch(tokensRecipient, cfg.burner);
        if (ILBPStrategy(cfg.strategy).initializers(predicted).migrationBlock != cfg.migrationBlock) {
            revert InitializerNotRegisteredWithStrategy(predicted);
        }
    }

    /// @dev Deposit and distribute in one multicall
    function _execute(
        LaunchConfig memory cfg
    ) internal {
        address permit2 = ILiquidityLauncher(cfg.launcher).permit2();
        IERC20(cfg.bws).forceApprove(permit2, ArbitrumConfig.CCA_BUCKET);
        IPermit2(permit2)
            .approve(cfg.bws, cfg.launcher, uint160(ArbitrumConfig.CCA_BUCKET), uint48(block.timestamp + 1 days));

        // configData = abi.encode(MigratorParameters, abi.encode(AuctionParameters)).
        ILiquidityLauncher.Distribution memory distribution = ILiquidityLauncher.Distribution({
            strategy: cfg.strategy,
            amount: uint128(ArbitrumConfig.CCA_BUCKET),
            configData: abi.encode(buildMigratorParameters(cfg), abi.encode(buildAuctionParameters(cfg)))
        });
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ILiquidityLauncher.depositToken, (cfg.bws, uint160(ArbitrumConfig.CCA_BUCKET)));
        calls[1] = abi.encodeCall(ILiquidityLauncher.distributeToken, (cfg.bws, distribution, cfg.salt));
        ILiquidityLauncher(cfg.launcher).multicall(calls);
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
        cfg.tickSpacingQ96 = vm.envOr("CCA_TICK_SPACING_Q96", ArbitrumConfig.CCA_TICK_SPACING_Q96);
        cfg.floorPriceQ96 = vm.envOr("CCA_FLOOR_PRICE_Q96", ArbitrumConfig.CCA_FLOOR_PRICE_Q96);
        cfg.requiredCurrencyRaised =
            _envU128("CCA_REQUIRED_CURRENCY_RAISED", ArbitrumConfig.CCA_REQUIRED_CURRENCY_RAISED);
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
        string memory name,
        uint128 defaultValue
    ) internal view returns (uint128) {
        uint256 v = vm.envOr(name, uint256(defaultValue));
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

// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {LaunchBwlkCca} from "script/bwlk/06_LaunchBwlkCca.s.sol";
import {EthereumConfig} from "script/bwlk/EthereumConfig.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ICcaAuctionFactory} from "src/interfaces/ICcaAuctionFactory.sol";
import {UnsoldBurner} from "src/token/UnsoldBurner.sol";
import {MockERC20} from "test/bwlk/UnsoldBurnerMocks.sol";
import {
    MockPermit2,
    MockLiquidityLauncher,
    MockLBPStrategy,
    MockLaunchCcaFactory,
    MockLaunchCcaAuction,
    MockLaunchVoter,
    MockLaunchLocker
} from "test/bwlk/LaunchCcaMocks.sol";

/// @title LaunchBwlkCcaTest
/// @notice Unit coverage for script/bwlk/06_LaunchBwlkCca.s.sol against faithful launcher/strategy/
///         factory mocks: the full deposit+distribute multicall runs, the captured configData is
///         decoded back field by field, and every check() invariant reverts on the exact violation
///         it guards.
contract LaunchBwlkCcaTest is Test {
    uint256 internal constant BUCKET = EthereumConfig.CCA_BUCKET;
    uint256 internal constant AUCTION_SUPPLY = EthereumConfig.CCA_AUCTION_SUPPLY;
    uint256 internal constant LP_RESERVE = BUCKET - AUCTION_SUPPLY;
    uint24 internal constant MPS = 1e7;

    LaunchBwlkCca internal launchScript;
    MockERC20 internal bwlk;
    MockPermit2 internal permit2;
    MockLiquidityLauncher internal launcher;
    MockLaunchCcaFactory internal factory;
    MockLBPStrategy internal strategy;
    MockLaunchVoter internal voter;
    MockLaunchLocker internal locker;
    UnsoldBurner internal burner;

    address internal recipient = makeAddr("recipient");
    address internal registrar = makeAddr("registrar");
    address internal positionManager = makeAddr("positionManager");
    address internal poolManager = makeAddr("poolManager");

    function setUp() public {
        launchScript = new LaunchBwlkCca();
        bwlk = new MockERC20("Boardwalk", "BWLK");
        bwlk.mint(address(launchScript), BUCKET);

        permit2 = new MockPermit2();
        launcher = new MockLiquidityLauncher(address(permit2));
        factory = new MockLaunchCcaFactory();
        strategy = new MockLBPStrategy(address(factory), positionManager, poolManager);
        voter = new MockLaunchVoter(EthereumConfig.POOL_FEE, EthereumConfig.POOL_TICK_SPACING);
        locker = new MockLaunchLocker(address(voter), address(0), address(bwlk), registrar, positionManager);
        burner = new UnsoldBurner(address(bwlk));

        vm.roll(1000);
    }

    function _cfg() internal view returns (LaunchBwlkCca.LaunchConfig memory cfg) {
        cfg.wallet = address(launchScript);
        cfg.bwlk = address(bwlk);
        cfg.launcher = address(launcher);
        cfg.strategy = address(strategy);
        cfg.voter = address(voter);
        cfg.lpLocker = address(locker);
        cfg.burner = address(burner);
        cfg.recipient = recipient;
        cfg.startBlock = uint64(block.number + 10);
        cfg.endBlock = uint64(block.number + 110);
        // Per Uniswap's guidance, claims and migration both open the block after close.
        cfg.claimBlock = cfg.endBlock + 1;
        cfg.migrationBlock = cfg.endBlock + 1;
        cfg.tickSpacingQ96 = uint256(1) << 96;
        cfg.floorPriceQ96 = uint256(1000) << 96;
        cfg.requiredCurrencyRaised = uint128(1 ether);
        cfg.zeroGraduationAttested = false;
        // Two 1%-mps steps of 50 blocks each: sums to 1e7 and spans exactly start..end.
        cfg.auctionStepsData = abi.encodePacked(uint24(100_000), uint40(50), uint24(100_000), uint40(50));
        cfg.salt = bytes32(0);
    }

    // ---- happy path ----

    function test_Launch_ExecutesAtomicallyAndEncodesEveryField() public {
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        address predicted = launchScript.predictAuction(cfg);

        address auction = launchScript.launch(cfg);
        assertEq(auction, predicted, "launch returns the CREATE2-predicted auction");

        // Deposit leg: pulled from the script wallet via Permit2, exact bucket.
        assertEq(launcher.lastDepositToken(), address(bwlk), "deposit token");
        assertEq(launcher.lastDepositAmount(), uint160(BUCKET), "deposit amount");
        assertEq(launcher.lastDepositCaller(), address(launchScript), "deposit caller preserved by multicall");
        // Both legs ran inside one multicall: tokens parked in the launcher between separate txs
        // would be distributable by anyone.
        assertTrue(launcher.depositViaMulticall(), "deposit executed inside the multicall");
        assertTrue(launcher.distributeViaMulticall(), "distribute executed inside the same multicall");

        // Permit2 approval: exact-sized for the launcher and fully consumed by the pull.
        assertEq(permit2.lastApproveToken(), address(bwlk), "permit2 token");
        assertEq(permit2.lastApproveSpender(), address(launcher), "permit2 spender");
        assertEq(permit2.lastApproveAmount(), uint160(BUCKET), "permit2 amount");
        (uint160 remaining,) = permit2.allowance(address(launchScript), address(bwlk), address(launcher));
        assertEq(remaining, 0, "permit2 allowance consumed to zero");
        assertEq(bwlk.allowance(address(launchScript), address(permit2)), 0, "ERC20 allowance consumed to zero");

        // Distribute leg capture.
        assertEq(launcher.lastDistributeToken(), address(bwlk), "distribute token");
        assertEq(launcher.lastStrategy(), address(strategy), "strategy");
        assertEq(launcher.lastAmount(), uint128(BUCKET), "distribution amount");
        assertEq(launcher.lastSalt(), bytes32(0), "salt");
        assertEq(launcher.lastDistributeCaller(), address(launchScript), "distribute caller preserved");

        // Decode the captured configData back: outer (MigratorParameters, bytes).
        (ILBPStrategy.MigratorParameters memory mig, bytes memory inner) =
            abi.decode(launcher.lastConfigData(), (ILBPStrategy.MigratorParameters, bytes));
        assertEq(mig.token, address(bwlk), "mig.token");
        assertEq(mig.currency, address(0), "mig.currency is native ETH");
        assertEq(mig.migrationBlock, cfg.migrationBlock, "mig.migrationBlock");
        assertEq(mig.reservedTokenAmountForLP, uint128(LP_RESERVE), "mig.reservedTokenAmountForLP");
        assertEq(mig.recipient, recipient, "mig.recipient");
        assertEq(mig.positionRecipient, address(locker), "mig.positionRecipient is the locker");
        assertEq(mig.poolParameters.fee, EthereumConfig.POOL_FEE, "pool fee from the voter");
        assertEq(mig.poolParameters.tickSpacing, EthereumConfig.POOL_TICK_SPACING, "pool tickSpacing from the voter");
        assertEq(mig.poolParameters.hook, address(0), "pool hook unset at launch");

        // One full-range sentinel definition, no per-position recipient override.
        ILBPStrategy.PositionDefinition[] memory defs =
            abi.decode(mig.positionDefinitions, (ILBPStrategy.PositionDefinition[]));
        assertEq(defs.length, 1, "one position definition");
        assertEq(defs[0].offsetLower, -887_272, "full-range sentinel lower");
        assertEq(defs[0].offsetUpper, 887_272, "full-range sentinel upper");
        assertEq(defs[0].weight, MPS, "100% weight");
        assertEq(defs[0].overridePositionRecipient, address(0), "no recipient override");

        // 100% of the raise allocated to LP from the first wei.
        ILBPStrategy.LiquidityAllocationBracket[] memory brackets =
            abi.decode(mig.lpAllocationSchedule, (ILBPStrategy.LiquidityAllocationBracket[]));
        assertEq(brackets.length, 1, "one bracket");
        assertEq(brackets[0].lowerThreshold, 0, "bracket starts at 0");
        assertEq(brackets[0].rate, MPS, "100% rate");

        // Inner AuctionParameters.
        ICcaAuctionFactory.AuctionParameters memory auc = abi.decode(inner, (ICcaAuctionFactory.AuctionParameters));
        assertEq(auc.currency, address(0), "auction currency is native ETH");
        assertEq(auc.tokensRecipient, address(burner), "unsold sink is the burner");
        assertEq(auc.fundsRecipient, address(strategy), "fundsRecipient is the strategy");
        assertEq(auc.startBlock, cfg.startBlock, "startBlock");
        assertEq(auc.endBlock, cfg.endBlock, "endBlock");
        assertEq(auc.claimBlock, cfg.claimBlock, "claimBlock");
        assertEq(auc.tickSpacing, cfg.tickSpacingQ96, "tickSpacing Q96");
        assertEq(auc.validationHook, address(0), "no validation hook");
        assertEq(auc.floorPrice, cfg.floorPriceQ96, "floorPrice Q96");
        assertEq(auc.requiredCurrencyRaised, cfg.requiredCurrencyRaised, "graduation threshold");
        assertEq(auc.auctionStepsData, cfg.auctionStepsData, "steps bytes");

        // The deployed auction stored the same wiring.
        MockLaunchCcaAuction deployed = MockLaunchCcaAuction(auction);
        assertEq(deployed.token(), address(bwlk), "auction token");
        assertEq(deployed.totalSupply(), uint128(AUCTION_SUPPLY), "auction offered supply");
        assertEq(deployed.tokensRecipient(), address(burner), "auction tokensRecipient");
        assertEq(deployed.fundsRecipient(), address(strategy), "auction fundsRecipient");

        // Registered with the strategy (the invariant that makes migrate() callable).
        assertEq(
            strategy.initializers(auction).migrationBlock, cfg.migrationBlock, "initializer registered with strategy"
        );

        // Token split: auction supply to the auction, LP reserve to the strategy, nothing stranded.
        assertEq(bwlk.balanceOf(auction), AUCTION_SUPPLY, "auction holds the offered supply");
        assertEq(bwlk.balanceOf(address(strategy)), LP_RESERVE, "strategy holds the LP reserve");
        assertEq(bwlk.balanceOf(address(launcher)), 0, "nothing stranded in the launcher");
        assertEq(bwlk.balanceOf(address(launchScript)), 0, "bucket fully spent");
    }

    function test_Launch_ZeroThreshold_PassesWhenAttested() public {
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        cfg.requiredCurrencyRaised = 0;
        cfg.zeroGraduationAttested = true;
        address auction = launchScript.launch(cfg);
        assertEq(MockLaunchCcaAuction(auction).auctionParameters().requiredCurrencyRaised, 0, "zero threshold kept");
    }

    // ---- launch defaults ----

    /// @dev Pins the announced BWLK supply split as literals - a typo'd constant would otherwise
    ///      only surface at deploy time.
    function test_Config_SupplySplitMatchesAnnouncedValues() public pure {
        assertEq(EthereumConfig.TOTAL_SUPPLY, 3_150_000e18, "total supply");
        assertEq(EthereumConfig.MIGRATION_POOL, 2_711_068e18, "migration pool (86.07%)");
        assertEq(EthereumConfig.CCA_BUCKET, 315_000e18, "CCA bucket (10%)");
        assertEq(EthereumConfig.CCA_AUCTION_SUPPLY, 157_500e18, "CCA sale (5%)");
        assertEq(EthereumConfig.CCA_BUCKET - EthereumConfig.CCA_AUCTION_SUPPLY, 157_500e18, "LP seed (5%)");
        assertEq(EthereumConfig.LP_INCENTIVES, 123_932e18, "LP incentives (3.93%)");
        assertEq(
            EthereumConfig.MIGRATION_POOL + EthereumConfig.CCA_BUCKET + EthereumConfig.LP_INCENTIVES,
            EthereumConfig.TOTAL_SUPPLY,
            "buckets sum to the fixed supply"
        );
    }

    // ---- default supply schedule ----

    /// @dev Parses one packed 8-byte step: uint24 mps + uint40 blockDelta, big-endian.
    function _step(
        bytes memory steps,
        uint256 i
    ) internal pure returns (uint256 mps, uint256 delta) {
        uint256 o = i * 8;
        mps = (uint256(uint8(steps[o])) << 16) | (uint256(uint8(steps[o + 1])) << 8) | uint256(uint8(steps[o + 2]));
        delta = (uint256(uint8(steps[o + 3])) << 32) | (uint256(uint8(steps[o + 4])) << 24)
            | (uint256(uint8(steps[o + 5])) << 16) | (uint256(uint8(steps[o + 6])) << 8) | uint256(uint8(steps[o + 7]));
    }

    /// @dev The generated schedule must satisfy the CCA constructor invariants (sum to 1e7, span
    ///      start..end exactly, no empty steps) and the uniswap-cca shape (12 ramp steps whose
    ///      release rate never decreases, then >= 25% of supply in the final block) at every
    ///      realistic span, including the ~1.61M-block launch window.
    function test_DefaultSchedule_ShapeAndInvariantsAcrossSpans() public view {
        uint256[4] memory spans = [uint256(10_000), 86_401, 1_614_393, 3_000_000];
        for (uint256 s = 0; s < spans.length; s++) {
            uint64 startBlock = 1000;
            uint64 endBlock = uint64(1000 + spans[s]);
            bytes memory steps = launchScript.defaultAuctionSchedule(startBlock, endBlock);
            assertEq(steps.length, 13 * 8, "12 ramp steps + final block");

            uint256 sumMps;
            uint256 sumDelta;
            uint256 prevRate;
            for (uint256 i = 0; i < 13; i++) {
                (uint256 mps, uint256 delta) = _step(steps, i);
                assertGt(delta, 0, "no empty steps");
                sumMps += mps * delta;
                sumDelta += delta;
                if (i < 12) {
                    assertGe(mps, prevRate, "release rate never decreases along the ramp");
                    prevRate = mps;
                } else {
                    assertEq(delta, 1, "final step is one block");
                    assertGe(mps, 2_500_000, "final block carries >= 25% of supply");
                }
            }
            assertEq(sumMps, 1e7, "mps*delta sums to the full supply");
            assertEq(sumDelta, spans[s], "deltas span start..end exactly");
        }
    }

    function test_Launch_WithDefaultSchedule() public {
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        cfg.endBlock = cfg.startBlock + 10_000;
        cfg.claimBlock = cfg.endBlock + 1;
        cfg.migrationBlock = cfg.endBlock + 1;
        cfg.auctionStepsData = launchScript.defaultAuctionSchedule(cfg.startBlock, cfg.endBlock);

        address auction = launchScript.launch(cfg);

        (, bytes memory inner) = abi.decode(launcher.lastConfigData(), (ILBPStrategy.MigratorParameters, bytes));
        ICcaAuctionFactory.AuctionParameters memory auc = abi.decode(inner, (ICcaAuctionFactory.AuctionParameters));
        assertEq(auc.auctionStepsData, cfg.auctionStepsData, "generated schedule passed through");
        assertEq(MockLaunchCcaAuction(auction).endBlock(), cfg.endBlock, "auction committed to the same window");
    }

    function test_RevertWhen_DefaultScheduleSpanInvalid() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchBwlkCca.ScheduleSpanInvalid.selector, 1000, 1000));
        launchScript.defaultAuctionSchedule(1000, 1000);
    }

    // ---- launch() + check() reverts ----

    function test_RevertWhen_WalletIsNotTheScript() public {
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        cfg.wallet = address(this);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwlkCca.WalletMismatch.selector, address(this), address(launchScript))
        );
        launchScript.launch(cfg);
    }

    function test_RevertWhen_WalletMissesTheBucket() public {
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        cfg.wallet = makeAddr("poor");
        vm.expectRevert(abi.encodeWithSelector(LaunchBwlkCca.WalletBucketMissing.selector, cfg.wallet, 0, BUCKET));
        launchScript.check(cfg);
    }

    function test_RevertWhen_BurnerBurnsTheWrongToken() public {
        MockERC20 other = new MockERC20("Other", "O");
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        cfg.burner = address(new UnsoldBurner(address(other)));
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwlkCca.BurnerBwlkMismatch.selector, address(other), address(bwlk))
        );
        launchScript.check(cfg);
    }

    function test_RevertWhen_LockerBoundToAnotherVoter() public {
        address otherVoter = makeAddr("otherVoter");
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        cfg.lpLocker = address(new MockLaunchLocker(otherVoter, address(0), address(bwlk), registrar, positionManager));
        vm.expectRevert(abi.encodeWithSelector(LaunchBwlkCca.LockerVoterMismatch.selector, otherVoter, address(voter)));
        launchScript.check(cfg);
    }

    function test_RevertWhen_LockerCurrenciesWrong() public {
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        cfg.lpLocker =
            address(new MockLaunchLocker(address(voter), address(bwlk), address(bwlk), registrar, positionManager));
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwlkCca.LockerCurrenciesWrong.selector, address(bwlk), address(bwlk))
        );
        launchScript.check(cfg);
    }

    function test_RevertWhen_RegistrarAlreadyRenounced() public {
        locker.setRegistrar(address(0));
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        vm.expectRevert(LaunchBwlkCca.RegistrarAlreadyRenounced.selector);
        launchScript.check(cfg);
    }

    function test_RevertWhen_PositionManagersDiverge() public {
        address otherPm = makeAddr("otherPm");
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        cfg.strategy = address(new MockLBPStrategy(address(factory), otherPm, poolManager));
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwlkCca.PositionManagerMismatch.selector, otherPm, positionManager)
        );
        launchScript.check(cfg);
    }

    function test_RevertWhen_PoolHooksAlreadySet() public {
        voter.setPoolHooks(address(0));
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        vm.expectRevert(LaunchBwlkCca.PoolHooksAlreadySet.selector);
        launchScript.check(cfg);
    }

    function test_RevertWhen_StartBlockNotInFuture() public {
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        cfg.startBlock = uint64(block.number);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwlkCca.StartBlockNotInFuture.selector, cfg.startBlock, block.number)
        );
        launchScript.check(cfg);
    }

    function test_RevertWhen_ZeroThresholdUnattested() public {
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        cfg.requiredCurrencyRaised = 0;
        vm.expectRevert(LaunchBwlkCca.GraduationThresholdZeroUnattested.selector);
        launchScript.check(cfg);
    }

    // ---- verifyLaunch ----

    function test_VerifyLaunch_RevertWhen_AuctionNotDeployed() public {
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();
        address ghost = makeAddr("ghost");
        vm.expectRevert(abi.encodeWithSelector(LaunchBwlkCca.AuctionNotDeployed.selector, ghost));
        launchScript.verifyLaunch(cfg, ghost);
    }

    function test_VerifyLaunch_RevertWhen_WiringDiverges() public {
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();

        // Wrong tokensRecipient.
        ICcaAuctionFactory.AuctionParameters memory p = launchScript.buildAuctionParameters(cfg);
        p.tokensRecipient = makeAddr("notBurner");
        address a = address(new MockLaunchCcaAuction(address(bwlk), uint128(AUCTION_SUPPLY), p));
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchBwlkCca.AuctionTokensRecipientMismatch.selector, makeAddr("notBurner"), address(burner)
            )
        );
        launchScript.verifyLaunch(cfg, a);

        // Correctly wired but never registered with the strategy: the stuck-forever case.
        a = address(
            new MockLaunchCcaAuction(address(bwlk), uint128(AUCTION_SUPPLY), launchScript.buildAuctionParameters(cfg))
        );
        vm.expectRevert(abi.encodeWithSelector(LaunchBwlkCca.InitializerNotRegisteredWithStrategy.selector, a));
        launchScript.verifyLaunch(cfg, a);
    }
}

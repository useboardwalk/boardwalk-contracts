// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {LaunchBwsCca} from "script/bws/06_LaunchBwsCca.s.sol";
import {ArbitrumConfig} from "script/bws/ArbitrumConfig.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ICcaAuctionFactory} from "src/interfaces/ICcaAuctionFactory.sol";
import {UnsoldBurner} from "src/token/UnsoldBurner.sol";
import {MockERC20} from "test/bws/UnsoldBurnerMocks.sol";
import {
    MockPermit2,
    MockLiquidityLauncher,
    MockLBPStrategy,
    MockLaunchCcaFactory,
    MockLaunchCcaAuction,
    MockLaunchVoter,
    MockLaunchLocker
} from "test/bws/LaunchCcaMocks.sol";

/// @title LaunchBwsCcaTest
/// @notice Unit coverage for script/bws/06_LaunchBwsCca.s.sol against faithful launcher/strategy/
///         factory mocks: the full deposit+distribute multicall runs, the captured configData is
///         decoded back field by field, and every pre-broadcast sanity check reverts on the exact
///         violation it guards.
contract LaunchBwsCcaTest is Test {
    uint256 internal constant BUCKET = ArbitrumConfig.CCA_BUCKET;
    uint256 internal constant AUCTION_SUPPLY = ArbitrumConfig.CCA_AUCTION_SUPPLY;
    uint256 internal constant LP_RESERVE = BUCKET - AUCTION_SUPPLY;
    uint24 internal constant MPS = 1e7;

    LaunchBwsCca internal launchScript;
    MockERC20 internal bws;
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
        launchScript = new LaunchBwsCca();
        bws = new MockERC20("Boardwalk", "BWS");
        // The check() supply shape-check expects the genuine fixed supply; the script holds the bucket.
        bws.mint(address(launchScript), BUCKET);
        bws.mint(address(this), ArbitrumConfig.TOTAL_SUPPLY - BUCKET);

        permit2 = new MockPermit2();
        launcher = new MockLiquidityLauncher(address(permit2));
        factory = new MockLaunchCcaFactory();
        strategy = new MockLBPStrategy(address(factory), positionManager, poolManager);
        voter = new MockLaunchVoter(ArbitrumConfig.POOL_FEE, ArbitrumConfig.POOL_TICK_SPACING);
        locker = new MockLaunchLocker(address(voter), address(0), address(bws), registrar, positionManager);
        burner = new UnsoldBurner(address(bws));

        vm.roll(1000);
    }

    function _cfg() internal view returns (LaunchBwsCca.LaunchConfig memory cfg) {
        cfg.wallet = address(launchScript);
        cfg.bws = address(bws);
        cfg.launcher = address(launcher);
        cfg.strategy = address(strategy);
        cfg.voter = address(voter);
        cfg.lpLocker = address(locker);
        cfg.burner = address(burner);
        cfg.recipient = recipient;
        cfg.startBlock = uint64(block.number + 10);
        cfg.endBlock = uint64(block.number + 110);
        cfg.claimBlock = uint64(block.number + 120);
        cfg.migrationBlock = uint64(block.number + 130);
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
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        address predicted = launchScript.predictAuction(cfg);

        address auction = launchScript.launch(cfg);
        assertEq(auction, predicted, "launch returns the CREATE2-predicted auction");

        // Deposit leg: pulled from the script wallet via Permit2, exact bucket.
        assertEq(launcher.lastDepositToken(), address(bws), "deposit token");
        assertEq(launcher.lastDepositAmount(), uint160(BUCKET), "deposit amount");
        assertEq(launcher.lastDepositCaller(), address(launchScript), "deposit caller preserved by multicall");
        // The atomicity invariant the script's NatSpec relies on: both legs ran inside ONE multicall
        // (tokens parked in the launcher between separate txs would be distributable by anyone).
        assertTrue(launcher.depositViaMulticall(), "deposit executed inside the multicall");
        assertTrue(launcher.distributeViaMulticall(), "distribute executed inside the same multicall");

        // Permit2 approval: exact-sized for the launcher and fully consumed by the pull.
        assertEq(permit2.lastApproveToken(), address(bws), "permit2 token");
        assertEq(permit2.lastApproveSpender(), address(launcher), "permit2 spender");
        assertEq(permit2.lastApproveAmount(), uint160(BUCKET), "permit2 amount");
        (uint160 remaining,) = permit2.allowance(address(launchScript), address(bws), address(launcher));
        assertEq(remaining, 0, "permit2 allowance consumed to zero");
        assertEq(bws.allowance(address(launchScript), address(permit2)), 0, "ERC20 allowance consumed to zero");

        // Distribute leg capture.
        assertEq(launcher.lastDistributeToken(), address(bws), "distribute token");
        assertEq(launcher.lastStrategy(), address(strategy), "strategy");
        assertEq(launcher.lastAmount(), uint128(BUCKET), "distribution amount");
        assertEq(launcher.lastSalt(), bytes32(0), "salt");
        assertEq(launcher.lastDistributeCaller(), address(launchScript), "distribute caller preserved");

        // Decode the captured configData back: outer (MigratorParameters, bytes).
        (ILBPStrategy.MigratorParameters memory mig, bytes memory inner) =
            abi.decode(launcher.lastConfigData(), (ILBPStrategy.MigratorParameters, bytes));
        assertEq(mig.token, address(bws), "mig.token");
        assertEq(mig.currency, address(0), "mig.currency is native ETH");
        assertEq(mig.migrationBlock, cfg.migrationBlock, "mig.migrationBlock");
        assertEq(mig.reservedTokenAmountForLP, uint128(LP_RESERVE), "mig.reservedTokenAmountForLP");
        assertEq(mig.recipient, recipient, "mig.recipient");
        assertEq(mig.positionRecipient, address(locker), "mig.positionRecipient is the locker");
        assertEq(mig.poolParameters.fee, ArbitrumConfig.POOL_FEE, "pool fee from the voter");
        assertEq(mig.poolParameters.tickSpacing, ArbitrumConfig.POOL_TICK_SPACING, "pool tickSpacing from the voter");
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
        assertEq(deployed.token(), address(bws), "auction token");
        assertEq(deployed.totalSupply(), uint128(AUCTION_SUPPLY), "auction offered supply");
        assertEq(deployed.tokensRecipient(), address(burner), "auction tokensRecipient");
        assertEq(deployed.fundsRecipient(), address(strategy), "auction fundsRecipient");

        // Registered with the strategy (the invariant that makes migrate() callable).
        assertEq(
            strategy.initializers(auction).migrationBlock, cfg.migrationBlock, "initializer registered with strategy"
        );

        // Token split: auction supply to the auction, LP reserve to the strategy, nothing stranded.
        assertEq(bws.balanceOf(auction), AUCTION_SUPPLY, "auction holds the offered supply");
        assertEq(bws.balanceOf(address(strategy)), LP_RESERVE, "strategy holds the LP reserve");
        assertEq(bws.balanceOf(address(launcher)), 0, "nothing stranded in the launcher");
        assertEq(bws.balanceOf(address(launchScript)), 0, "bucket fully spent");
    }

    function test_Launch_ZeroThreshold_PassesWhenAttested() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.requiredCurrencyRaised = 0;
        cfg.zeroGraduationAttested = true;
        address auction = launchScript.launch(cfg);
        assertEq(MockLaunchCcaAuction(auction).auctionParameters().requiredCurrencyRaised, 0, "zero threshold kept");
    }

    // ---- launch-entry guards ----

    function test_RevertWhen_WalletIsNotTheScript() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.wallet = address(this);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwsCca.WalletMismatch.selector, address(this), address(launchScript))
        );
        launchScript.launch(cfg);
    }

    function test_RevertWhen_PredictedAuctionAlreadyDeployed() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        address predicted = launchScript.predictAuction(cfg);
        vm.etch(predicted, hex"01");
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.AuctionAlreadyDeployed.selector, predicted));
        launchScript.launch(cfg);
    }

    // ---- check(): token + bucket ----

    function test_RevertWhen_BwsHasNoCode() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.bws = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.BwsHasNoCode.selector, cfg.bws));
        launchScript.check(cfg);
    }

    function test_RevertWhen_BwsSupplyWrong() public {
        MockERC20 wrong = new MockERC20("Wrong", "W");
        wrong.mint(address(launchScript), BUCKET);
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.bws = address(wrong);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwsCca.BwsSupplyWrong.selector, BUCKET, ArbitrumConfig.TOTAL_SUPPLY)
        );
        launchScript.check(cfg);
    }

    function test_RevertWhen_WalletMissesTheBucket() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.wallet = makeAddr("poor");
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.WalletBucketMissing.selector, cfg.wallet, 0, BUCKET));
        launchScript.check(cfg);
    }

    // ---- check(): Uniswap side ----

    function test_RevertWhen_LauncherHasNoCode() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.launcher = makeAddr("eoaLauncher");
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.LauncherHasNoCode.selector, cfg.launcher));
        launchScript.check(cfg);
    }

    function test_RevertWhen_Permit2HasNoCode() public {
        address eoaPermit2 = makeAddr("eoaPermit2");
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.launcher = address(new MockLiquidityLauncher(eoaPermit2));
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.Permit2HasNoCode.selector, eoaPermit2));
        launchScript.check(cfg);
    }

    function test_RevertWhen_StrategyHasNoCode() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.strategy = makeAddr("eoaStrategy");
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.StrategyHasNoCode.selector, cfg.strategy));
        launchScript.check(cfg);
    }

    function test_RevertWhen_FactoryHasNoCode() public {
        address eoaFactory = makeAddr("eoaFactory");
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.strategy = address(new MockLBPStrategy(eoaFactory, positionManager, poolManager));
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.FactoryHasNoCode.selector, eoaFactory));
        launchScript.check(cfg);
    }

    function test_RevertWhen_PositionManagersDiverge() public {
        address otherPm = makeAddr("otherPm");
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.strategy = address(new MockLBPStrategy(address(factory), otherPm, poolManager));
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.PositionManagerMismatch.selector, otherPm, positionManager));
        launchScript.check(cfg);
    }

    // ---- check(): burner ----

    function test_RevertWhen_BurnerHasNoCode() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.burner = makeAddr("eoaBurner");
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.BurnerHasNoCode.selector, cfg.burner));
        launchScript.check(cfg);
    }

    function test_RevertWhen_BurnerBurnsTheWrongToken() public {
        MockERC20 other = new MockERC20("Other", "O");
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.burner = address(new UnsoldBurner(address(other)));
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.BurnerBwsMismatch.selector, address(other), address(bws)));
        launchScript.check(cfg);
    }

    // ---- check(): locker ----

    function test_RevertWhen_LockerBoundToAnotherVoter() public {
        address otherVoter = makeAddr("otherVoter");
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.lpLocker = address(new MockLaunchLocker(otherVoter, address(0), address(bws), registrar, positionManager));
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.LockerVoterMismatch.selector, otherVoter, address(voter)));
        launchScript.check(cfg);
    }

    function test_RevertWhen_LockerCurrenciesWrong() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.lpLocker =
            address(new MockLaunchLocker(address(voter), address(bws), address(bws), registrar, positionManager));
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.LockerCurrenciesWrong.selector, address(bws), address(bws)));
        launchScript.check(cfg);
    }

    function test_RevertWhen_RegistrarAlreadyRenounced() public {
        locker.setRegistrar(address(0));
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        vm.expectRevert(LaunchBwsCca.RegistrarAlreadyRenounced.selector);
        launchScript.check(cfg);
    }

    // ---- check(): voter ----

    function test_RevertWhen_PoolHooksAlreadySet() public {
        voter.setPoolHooks(address(0));
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        vm.expectRevert(LaunchBwsCca.PoolHooksAlreadySet.selector);
        launchScript.check(cfg);
    }

    function test_RevertWhen_VoterPoolParamsDivergeFromCanonical() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.voter = address(new MockLaunchVoter(3000, 60));
        cfg.lpLocker = address(new MockLaunchLocker(cfg.voter, address(0), address(bws), registrar, positionManager));
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwsCca.VoterPoolParamsUnexpected.selector, uint24(3000), int24(60))
        );
        launchScript.check(cfg);
    }

    // ---- check(): recipient ----

    function test_RevertWhen_RecipientInvalid() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.recipient = address(0);
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.RecipientInvalid.selector, address(0)));
        launchScript.check(cfg);

        cfg.recipient = address(1);
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.RecipientInvalid.selector, address(1)));
        launchScript.check(cfg);

        cfg.recipient = address(2);
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.RecipientInvalid.selector, address(2)));
        launchScript.check(cfg);
    }

    // ---- check(): blocks ----

    function test_RevertWhen_StartBlockNotInFuture() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.startBlock = uint64(block.number);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwsCca.StartBlockNotInFuture.selector, cfg.startBlock, block.number)
        );
        launchScript.check(cfg);
    }

    function test_RevertWhen_BlockOrderInvalid() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.endBlock = cfg.startBlock; // start >= end
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchBwsCca.BlockOrderInvalid.selector,
                cfg.startBlock,
                cfg.endBlock,
                cfg.claimBlock,
                cfg.migrationBlock
            )
        );
        launchScript.check(cfg);

        cfg = _cfg();
        cfg.claimBlock = cfg.endBlock - 1; // claim < end
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchBwsCca.BlockOrderInvalid.selector,
                cfg.startBlock,
                cfg.endBlock,
                cfg.claimBlock,
                cfg.migrationBlock
            )
        );
        launchScript.check(cfg);

        cfg = _cfg();
        cfg.migrationBlock = cfg.endBlock; // migration <= end
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchBwsCca.BlockOrderInvalid.selector,
                cfg.startBlock,
                cfg.endBlock,
                cfg.claimBlock,
                cfg.migrationBlock
            )
        );
        launchScript.check(cfg);
    }

    // ---- check(): steps ----

    function test_RevertWhen_StepDataLengthInvalid() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.auctionStepsData = "";
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.StepDataLengthInvalid.selector, 0));
        launchScript.check(cfg);

        cfg.auctionStepsData = hex"01020304050607"; // 7 bytes
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.StepDataLengthInvalid.selector, 7));
        launchScript.check(cfg);
    }

    function test_RevertWhen_StepBlockDeltaZero() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.auctionStepsData = abi.encodePacked(uint24(100_000), uint40(100), uint24(100_000), uint40(0));
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.StepBlockDeltaZero.selector, 1));
        launchScript.check(cfg);
    }

    function test_RevertWhen_StepMpsSumWrong() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        // 2 * 90_000 * 50 = 9_000_000 != 1e7
        cfg.auctionStepsData = abi.encodePacked(uint24(90_000), uint40(50), uint24(90_000), uint40(50));
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.StepMpsSumWrong.selector, 9_000_000));
        launchScript.check(cfg);
    }

    function test_RevertWhen_StepSpanDoesNotReachEndBlock() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        // Sums to exactly 1e7 but spans 50 blocks while end - start = 100.
        cfg.auctionStepsData = abi.encodePacked(uint24(200_000), uint40(50));
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwsCca.StepSpanMismatch.selector, uint256(cfg.startBlock) + 50, cfg.endBlock)
        );
        launchScript.check(cfg);
    }

    // ---- check(): graduation + prices ----

    function test_RevertWhen_ZeroThresholdUnattested() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.requiredCurrencyRaised = 0;
        vm.expectRevert(LaunchBwsCca.GraduationThresholdZeroUnattested.selector);
        launchScript.check(cfg);
    }

    /// @dev The mirrored MaxBidPriceLib bound for the fixed 219,466e18 supply:
    ///      min(((2^154)/supply)^2, 2^222/supply).
    function _maxBid() internal pure returns (uint256) {
        uint256 liquidityBound = ((uint256(1) << 154) / AUCTION_SUPPLY) ** 2;
        uint256 currencyBound = (uint256(1) << 222) / AUCTION_SUPPLY;
        return liquidityBound < currencyBound ? liquidityBound : currencyBound;
    }

    function test_RevertWhen_PriceUnderMinimum() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.tickSpacingQ96 = 1; // < TickStorage MIN_TICK_SPACING (2)
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.PriceUnderMinimum.selector, uint256(1), cfg.floorPriceQ96));
        launchScript.check(cfg);

        cfg = _cfg();
        cfg.floorPriceQ96 = uint256(1) << 32; // < TickStorage MIN_FLOOR_PRICE (2^32 + 1): the forgot-<<96 typo
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwsCca.PriceUnderMinimum.selector, cfg.tickSpacingQ96, uint256(1) << 32)
        );
        launchScript.check(cfg);
    }

    function test_RevertWhen_FloorNotAtTickBoundary() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.floorPriceQ96 = (uint256(1000) << 96) + 1; // not a multiple of the 1<<96 tick spacing
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwsCca.FloorNotAtTickBoundary.selector, cfg.floorPriceQ96, cfg.tickSpacingQ96)
        );
        launchScript.check(cfg);
    }

    function test_Check_PassesAtExactMaxBidBoundary() public view {
        // Pins the mirrored MaxBidPriceLib value: the largest tick-aligned floor passes...
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.tickSpacingQ96 = 2;
        uint256 floorAtCap = _maxBid() - 2;
        if (floorAtCap % 2 != 0) floorAtCap -= 1;
        cfg.floorPriceQ96 = floorAtCap;
        launchScript.check(cfg);
    }

    function test_RevertWhen_FloorPastMaxBid() public {
        // ...and one tick further reverts with the exact bound in the error.
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        cfg.tickSpacingQ96 = 2;
        uint256 maxBid = _maxBid();
        uint256 floorAtCap = maxBid - 2;
        if (floorAtCap % 2 != 0) floorAtCap -= 1;
        cfg.floorPriceQ96 = floorAtCap + 2;
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwsCca.PriceOverMaxBid.selector, uint256(2), floorAtCap + 2, maxBid)
        );
        launchScript.check(cfg);
    }

    // ---- verifyLaunch ----

    function _auctionWith(
        address token,
        uint128 supply,
        ICcaAuctionFactory.AuctionParameters memory params
    ) internal returns (address) {
        return address(new MockLaunchCcaAuction(token, supply, params));
    }

    function _validParams(
        LaunchBwsCca.LaunchConfig memory cfg
    ) internal view returns (ICcaAuctionFactory.AuctionParameters memory) {
        return launchScript.buildAuctionParameters(cfg);
    }

    function test_VerifyLaunch_RevertWhen_AuctionNotDeployed() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();
        address ghost = makeAddr("ghost");
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.AuctionNotDeployed.selector, ghost));
        launchScript.verifyLaunch(cfg, ghost);
    }

    function test_VerifyLaunch_RevertWhen_WiringDiverges() public {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();

        // Wrong token.
        address a = _auctionWith(makeAddr("otherToken"), uint128(AUCTION_SUPPLY), _validParams(cfg));
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwsCca.AuctionTokenMismatch.selector, makeAddr("otherToken"), address(bws))
        );
        launchScript.verifyLaunch(cfg, a);

        // Non-native currency.
        ICcaAuctionFactory.AuctionParameters memory p = _validParams(cfg);
        p.currency = address(bws);
        a = _auctionWith(address(bws), uint128(AUCTION_SUPPLY), p);
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.AuctionCurrencyNotNative.selector, address(bws)));
        launchScript.verifyLaunch(cfg, a);

        // Wrong tokensRecipient.
        p = _validParams(cfg);
        p.tokensRecipient = makeAddr("notBurner");
        a = _auctionWith(address(bws), uint128(AUCTION_SUPPLY), p);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchBwsCca.AuctionTokensRecipientMismatch.selector, makeAddr("notBurner"), address(burner)
            )
        );
        launchScript.verifyLaunch(cfg, a);

        // Wrong fundsRecipient.
        p = _validParams(cfg);
        p.fundsRecipient = makeAddr("notStrategy");
        a = _auctionWith(address(bws), uint128(AUCTION_SUPPLY), p);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchBwsCca.AuctionFundsRecipientMismatch.selector, makeAddr("notStrategy"), address(strategy)
            )
        );
        launchScript.verifyLaunch(cfg, a);

        // Wrong offered supply.
        a = _auctionWith(address(bws), uint128(AUCTION_SUPPLY - 1), _validParams(cfg));
        vm.expectRevert(
            abi.encodeWithSelector(LaunchBwsCca.AuctionSupplyMismatch.selector, AUCTION_SUPPLY - 1, AUCTION_SUPPLY)
        );
        launchScript.verifyLaunch(cfg, a);

        // Correctly wired but never registered with the strategy: the stuck-forever case.
        a = _auctionWith(address(bws), uint128(AUCTION_SUPPLY), _validParams(cfg));
        vm.expectRevert(abi.encodeWithSelector(LaunchBwsCca.InitializerNotRegisteredWithStrategy.selector, a));
        launchScript.verifyLaunch(cfg, a);
    }
}

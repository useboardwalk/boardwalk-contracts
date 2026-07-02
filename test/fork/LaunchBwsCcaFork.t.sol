// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LaunchBwsCca} from "script/bws/06_LaunchBwsCca.s.sol";
import {ArbitrumConfig} from "script/bws/ArbitrumConfig.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {BWS} from "src/token/BWS.sol";
import {UnsoldBurner} from "src/token/UnsoldBurner.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {MockLaunchVoter} from "test/bws/LaunchCcaMocks.sol";

/// @dev The real ContinuousClearingAuction surface this test drives/reads.
interface ICcaAuctionLive {
    function submitBid(
        uint256 maxPriceQ96,
        uint128 amount,
        address owner,
        bytes calldata hookData
    ) external payable returns (uint256);
    function isGraduated() external view returns (bool);
    function currencyRaised() external view returns (uint256);
    function totalSupply() external view returns (uint128);
    function sweepUnsoldTokensBlock() external view returns (uint256);
}

/// @dev v4 PoolKey mirror for getPoolAndPositionInfo asserts.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev Real v4 PositionManager surface this test reads.
interface IPositionManagerLive {
    function ownerOf(
        uint256 tokenId
    ) external view returns (address);
    function getPoolAndPositionInfo(
        uint256 tokenId
    ) external view returns (PoolKey memory, uint256);
    function getPositionLiquidity(
        uint256 tokenId
    ) external view returns (uint128);
}

/// @title LaunchBwsCcaForkTest
/// @notice Arbitrum-fork test for the FULL launch pipeline against the deployed Uniswap
///         LiquidityLauncher + LBPStrategy: script 06's exact deposit+distribute multicall creates a
///         real registered auction, a real bid graduates it, `LBPStrategy.migrate` initializes the
///         v4 pool and mints the full-range LP to `LPLocker`, `registerPosition` locks it, and
///         `UnsoldBurner.sweep` burns the unsold supply. This is the launcher -> strategy ->
///         migrate -> LP-to-locker path that was previously only simulated.
/// @dev The only stub is `vm.mockCall`ing the ArbSys precompile (0x64) to drive the auction/strategy
///      L2 block clock - `vm.roll` has no effect on it (see UnsoldBurnerFork.t.sol). The voter is a
///      mock with the canonical pool immutables (the script/locker only read POOL_FEE /
///      POOL_TICK_SPACING / POOL_HOOKS / poolHooksSet); launcher, strategy, factory, auction,
///      PoolManager and PositionManager are all real deployed bytecode.
///      Run: forge test --match-contract LaunchBwsCcaForkTest --fork-url https://arb1.arbitrum.io/rpc
contract LaunchBwsCcaForkTest is Test {
    address internal constant LIQUIDITY_LAUNCHER = 0x00004c4ccc709Ef590F7C81102C0689F0263D4e9;
    address internal constant LBP_STRATEGY = 0x18608AD558dcD233F7854242bbAef73988Bee000;
    address internal constant POSITION_MANAGER = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;

    address internal constant ARB_SYS = 0x0000000000000000000000000000000000000064;
    bytes4 internal constant ARB_BLOCK_NUMBER_SELECTOR = 0xa3b1b31d;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant MIGRATION_FAILED_TOPIC = keccak256("MigrationFailed(address,bytes)");

    /// @dev Q96 tick spacing; floor and bids must be exact multiples. floor = 10 ticks ~= 1e-6
    ///      ETH-wei per BWS-wei, so a 0.001 ETH bid buys ~1000 BWS of the 219,466 offered.
    uint256 internal constant TICK_Q96 = (uint256(1) << 96) / 1e7;
    uint256 internal constant FLOOR_Q96 = 10 * TICK_Q96;
    uint256 internal constant BID_AMOUNT = 1e15; // 0.001 ETH
    uint128 internal constant REQUIRED_RAISE = 5e14; // graduation threshold, half the bid

    LaunchBwsCca internal launchScript;
    BWS internal bws;
    UnsoldBurner internal burner;
    MockLaunchVoter internal voter;
    LPLocker internal locker;

    address internal registrar = makeAddr("registrar");
    address internal treasury = makeAddr("treasury");
    address internal bidder = makeAddr("bidder");

    bool internal forked;

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function setUp() public {
        // Run with --fork-url, or self-fork from ARBITRUM_RPC_URL; without either the suite skips
        // (CI runs with no RPC configured).
        if (LIQUIDITY_LAUNCHER.code.length == 0) {
            string memory rpcUrl = vm.envOr("ARBITRUM_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) return;
            vm.createSelectFork(rpcUrl);
        }
        forked = true;
        require(LBP_STRATEGY.code.length > 0, "strategy missing");
        require(POSITION_MANAGER.code.length > 0, "position manager missing");

        launchScript = new LaunchBwsCca();
        bws = new BWS(address(this), address(this));
        // The script contract stands in for the bucket wallet (launch() executes the calls itself).
        bws.transfer(address(launchScript), ArbitrumConfig.CCA_BUCKET);

        burner = new UnsoldBurner(address(bws));
        voter = new MockLaunchVoter(ArbitrumConfig.POOL_FEE, ArbitrumConfig.POOL_TICK_SPACING);
        locker = new LPLocker(POSITION_MANAGER, address(voter), address(0), address(bws), registrar);
    }

    /// @dev Point the ArbSys-backed L2 clock (auction + strategy) at `b`.
    function _setArbBlock(
        uint256 b
    ) internal {
        vm.mockCall(ARB_SYS, abi.encodeWithSelector(ARB_BLOCK_NUMBER_SELECTOR), abi.encode(b));
    }

    function _cfg() internal view returns (LaunchBwsCca.LaunchConfig memory cfg) {
        uint64 baseBlock = uint64(block.number); // Arbitrum RPCs report the L2 height
        cfg.wallet = address(launchScript);
        cfg.bws = address(bws);
        cfg.launcher = LIQUIDITY_LAUNCHER;
        cfg.strategy = LBP_STRATEGY;
        cfg.voter = address(voter);
        cfg.lpLocker = address(locker);
        cfg.burner = address(burner);
        cfg.recipient = treasury;
        cfg.startBlock = baseBlock + 10;
        cfg.endBlock = baseBlock + 110;
        cfg.claimBlock = baseBlock + 120;
        cfg.migrationBlock = baseBlock + 130;
        cfg.tickSpacingQ96 = TICK_Q96;
        cfg.floorPriceQ96 = FLOOR_Q96;
        cfg.requiredCurrencyRaised = REQUIRED_RAISE;
        cfg.zeroGraduationAttested = false;
        // Two 1%-mps steps of 50 blocks each: sums to 1e7, spans exactly start..end.
        cfg.auctionStepsData = abi.encodePacked(uint24(100_000), uint40(50), uint24(100_000), uint40(50));
        cfg.salt = bytes32(0);
    }

    /// @dev End-to-end: script 06 -> real launcher/strategy -> real auction -> bid graduates it ->
    ///      permissionless migrate -> real v4 pool + LP minted to the locker -> registerPosition ->
    ///      unsold supply burned.
    function testFork_FullLaunchPipeline_MigratesLocksAndBurns() public onlyFork {
        LaunchBwsCca.LaunchConfig memory cfg = _cfg();

        // -- Launch (script 06's exact call path, incl. check + CREATE2 prediction + verification) --
        _setArbBlock(block.number); // the CCA constructor reads the ArbSys clock
        address auction = launchScript.launch(cfg);

        assertEq(bws.balanceOf(auction), ArbitrumConfig.CCA_AUCTION_SUPPLY, "auction funded with offered supply");
        assertEq(bws.balanceOf(address(launchScript)), 0, "bucket fully spent");

        // Byte-identity proof: the REAL strategy's stored MigratorParameters decode back through our
        // struct mirrors with every field intact.
        ILBPStrategy.MigratorParameters memory stored = ILBPStrategy(LBP_STRATEGY).initializers(auction);
        assertEq(stored.token, address(bws), "stored token");
        assertEq(stored.currency, address(0), "stored currency");
        assertEq(stored.migrationBlock, cfg.migrationBlock, "stored migrationBlock");
        assertEq(
            stored.reservedTokenAmountForLP,
            uint128(ArbitrumConfig.CCA_BUCKET - ArbitrumConfig.CCA_AUCTION_SUPPLY),
            "stored LP reserve"
        );
        assertEq(stored.recipient, treasury, "stored recipient");
        assertEq(stored.positionRecipient, address(locker), "stored positionRecipient");
        assertEq(stored.poolParameters.fee, ArbitrumConfig.POOL_FEE, "stored pool fee");
        assertEq(stored.poolParameters.tickSpacing, ArbitrumConfig.POOL_TICK_SPACING, "stored pool tickSpacing");
        assertEq(stored.poolParameters.hook, address(0), "stored hookless");

        // -- Bid enough to graduate (auction live, clock inside the bidding window) --
        _setArbBlock(cfg.startBlock + 1);
        vm.deal(bidder, 1 ether);
        uint256 maxPrice = FLOOR_Q96 + 2 * TICK_Q96; // tick-aligned, above the floor/clearing price
        vm.prank(bidder);
        ICcaAuctionLive(auction).submitBid{value: BID_AMOUNT}(maxPrice, uint128(BID_AMOUNT), bidder, "");

        // -- Migrate (permissionless; sweeps the raise, initializes the pool, mints LP to locker) --
        _setArbBlock(cfg.migrationBlock + 1);
        uint256 treasuryBwsBefore = bws.balanceOf(treasury);
        vm.recordLogs();
        ILBPStrategy(LBP_STRATEGY).migrate(auction);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // migrate() swallows tryMigrate failures into MigrationFailed + fund recovery; that path
        // means the pipeline is broken, so surface the revert reason instead of passing vacuously.
        uint256[] memory tokenIds = new uint256[](logs.length);
        uint256 mintCount;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == LBP_STRATEGY && logs[i].topics[0] == MIGRATION_FAILED_TOPIC) {
                console.logBytes(logs[i].data);
                fail("LBPStrategy.migrate recovered funds instead of migrating");
            }
            if (
                logs[i].emitter == POSITION_MANAGER && logs[i].topics.length == 4 && logs[i].topics[0] == TRANSFER_TOPIC
                    && address(uint160(uint256(logs[i].topics[1]))) == address(0)
                    && address(uint160(uint256(logs[i].topics[2]))) == address(locker)
            ) {
                tokenIds[mintCount++] = uint256(logs[i].topics[3]);
            }
        }
        assertGt(mintCount, 0, "at least one LP position minted to the locker");

        assertTrue(ICcaAuctionLive(auction).isGraduated(), "auction graduated");
        assertGe(ICcaAuctionLive(auction).currencyRaised(), REQUIRED_RAISE, "raise met the threshold");

        // The real v4 pool key behind every minted position matches the governance pool.
        IPositionManagerLive pm = IPositionManagerLive(POSITION_MANAGER);
        for (uint256 i = 0; i < mintCount; i++) {
            assertEq(pm.ownerOf(tokenIds[i]), address(locker), "locker owns the LP");
            (PoolKey memory key,) = pm.getPoolAndPositionInfo(tokenIds[i]);
            assertEq(key.currency0, address(0), "pool currency0 is native ETH");
            assertEq(key.currency1, address(bws), "pool currency1 is BWS");
            assertEq(key.fee, ArbitrumConfig.POOL_FEE, "pool fee");
            assertEq(key.tickSpacing, ArbitrumConfig.POOL_TICK_SPACING, "pool tickSpacing");
            assertEq(key.hooks, address(0), "hookless pool (not front-run)");
            assertGt(pm.getPositionLiquidity(tokenIds[i]), 0, "position has liquidity");
        }

        // The ETH side is the binding LP budget at these prices, so most of the 219,466 BWS reserve
        // returns to the treasury recipient.
        assertGt(bws.balanceOf(treasury), treasuryBwsBefore, "unused LP reserve swept to recipient");

        // -- Post-migrate governance wiring (runbook step 5) --
        voter.setPoolHooks(address(0)); // the one-shot hook commit, hookless as read from the pool
        for (uint256 i = 0; i < mintCount; i++) {
            vm.prank(registrar);
            locker.registerPosition(tokenIds[i]);
        }
        assertEq(locker.getLockedPositions().length, mintCount, "every minted position locked");
        vm.prank(registrar);
        locker.renounceRegistrar();
        assertEq(locker.registrar(), address(0), "registrar renounced");

        // -- Burn the unsold supply (runbook step 7) --
        uint256 auctionBalance = bws.balanceOf(auction);
        uint256 deadBefore = bws.balanceOf(DEAD);
        burner.sweep(auction);
        uint256 deadDelta = bws.balanceOf(DEAD) - deadBefore;
        assertGt(deadDelta, 0, "unsold supply burned");
        assertLt(deadDelta, ArbitrumConfig.CCA_AUCTION_SUPPLY, "partial sale: sold tokens stay claimable");
        assertEq(deadDelta + bws.balanceOf(auction), auctionBalance, "burn accounts for exactly the unsold part");
        assertEq(bws.balanceOf(address(burner)), 0, "burner holds nothing");
        assertTrue(ICcaAuctionLive(auction).sweepUnsoldTokensBlock() != 0, "auction marked swept");
    }
}

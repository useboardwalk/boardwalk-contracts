// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LaunchBwlkCca} from "script/bwlk/06_LaunchBwlkCca.s.sol";
import {EthereumConfig} from "script/bwlk/EthereumConfig.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {BWLK} from "src/token/BWLK.sol";
import {UnsoldBurner} from "src/token/UnsoldBurner.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {MockLaunchVoter} from "test/bwlk/LaunchCcaMocks.sol";

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

/// @title LaunchBwlkCcaForkTest
/// @notice Ethereum-mainnet-fork test for the FULL launch pipeline against the deployed Uniswap
///         LiquidityLauncher + LBPStrategy (v3.1.0): script 06's exact deposit+distribute multicall
///         creates a real registered auction, a real bid graduates it, `LBPStrategy.migrate`
///         initializes the v4 pool and mints the full-range LP to `LPLocker`, `registerPosition`
///         locks it, and `UnsoldBurner.sweep` burns the unsold supply.
/// @dev On mainnet the CCA's clock is plain block.number, so `vm.roll` drives it - no stubs at all;
///      launcher, strategy, factory, auction, PoolManager and PositionManager are real deployed
///      bytecode. The voter is a mock with the canonical pool immutables (the script/locker only
///      read POOL_FEE / POOL_TICK_SPACING / POOL_HOOKS / poolHooksSet).
///      Run: forge test --match-contract LaunchBwlkCcaForkTest --fork-url https://ethereum-rpc.publicnode.com
contract LaunchBwlkCcaForkTest is Test {
    address internal constant LIQUIDITY_LAUNCHER = 0x00004c4ccc709Ef590F7C81102C0689F0263D4e9;
    address internal constant LBP_STRATEGY = 0x49380c4EfaB1b491006aF7FabAB8B3459F0E6000;
    address internal constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant MIGRATION_FAILED_TOPIC = keccak256("MigrationFailed(address,bytes)");

    /// @dev Q96 tick spacing; floor and bids must be exact multiples. floor = 10 ticks ~= 1e-6
    ///      ETH-wei per BWLK-wei, so a 0.001 ETH bid buys ~1000 BWLK of the 219,466 offered.
    uint256 internal constant TICK_Q96 = (uint256(1) << 96) / 1e7;
    uint256 internal constant FLOOR_Q96 = 10 * TICK_Q96;
    uint256 internal constant BID_AMOUNT = 1e15; // 0.001 ETH
    uint128 internal constant REQUIRED_RAISE = 5e14; // graduation threshold, half the bid

    LaunchBwlkCca internal launchScript;
    BWLK internal bwlk;
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
        // Run with --fork-url, or self-fork from ETHEREUM_RPC_URL; without either the suite skips
        // (CI runs with no RPC configured).
        if (LIQUIDITY_LAUNCHER.code.length == 0) {
            string memory rpcUrl = vm.envOr("ETHEREUM_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) return;
            vm.createSelectFork(rpcUrl);
        }
        forked = true;
        require(LBP_STRATEGY.code.length > 0, "strategy missing");
        require(POSITION_MANAGER.code.length > 0, "position manager missing");

        launchScript = new LaunchBwlkCca();
        bwlk = new BWLK(address(this), address(this));
        // The script contract stands in for the bucket wallet (launch() executes the calls itself).
        bwlk.transfer(address(launchScript), EthereumConfig.CCA_BUCKET);

        burner = new UnsoldBurner(address(bwlk));
        voter = new MockLaunchVoter(EthereumConfig.POOL_FEE, EthereumConfig.POOL_TICK_SPACING);
        locker = new LPLocker(POSITION_MANAGER, address(voter), address(0), address(bwlk), registrar);
    }

    function _cfg() internal view returns (LaunchBwlkCca.LaunchConfig memory cfg) {
        uint64 baseBlock = uint64(block.number);
        cfg.wallet = address(launchScript);
        cfg.bwlk = address(bwlk);
        cfg.launcher = LIQUIDITY_LAUNCHER;
        cfg.strategy = LBP_STRATEGY;
        cfg.voter = address(voter);
        cfg.lpLocker = address(locker);
        cfg.burner = address(burner);
        cfg.recipient = treasury;
        cfg.startBlock = baseBlock + 10;
        cfg.endBlock = baseBlock + 10 + 10_000;
        // Per Uniswap's guidance, claims and migration both open the block after close.
        cfg.claimBlock = cfg.endBlock + 1;
        cfg.migrationBlock = cfg.endBlock + 1;
        cfg.tickSpacingQ96 = TICK_Q96;
        cfg.floorPriceQ96 = FLOOR_Q96;
        cfg.requiredCurrencyRaised = REQUIRED_RAISE;
        cfg.zeroGraduationAttested = false;
        // The production shape: the script-generated convex ramp + ~30% final block, validated
        // here by the real CCA constructor.
        cfg.auctionStepsData = launchScript.defaultAuctionSchedule(cfg.startBlock, cfg.endBlock);
        cfg.salt = bytes32(0);
    }

    /// @dev End-to-end: script 06 -> real launcher/strategy -> real auction -> bid graduates it ->
    ///      permissionless migrate -> real v4 pool + LP minted to the locker -> registerPosition ->
    ///      unsold supply burned.
    function testFork_FullLaunchPipeline_MigratesLocksAndBurns() public onlyFork {
        LaunchBwlkCca.LaunchConfig memory cfg = _cfg();

        // -- Launch (script 06's exact call path, incl. check + CREATE2 prediction + verification) --
        address auction = launchScript.launch(cfg);

        assertEq(bwlk.balanceOf(auction), EthereumConfig.CCA_AUCTION_SUPPLY, "auction funded with offered supply");
        assertEq(bwlk.balanceOf(address(launchScript)), 0, "bucket fully spent");

        // Byte-identity proof: the REAL strategy's stored MigratorParameters decode back through our
        // struct mirrors with every field intact.
        ILBPStrategy.MigratorParameters memory stored = ILBPStrategy(LBP_STRATEGY).initializers(auction);
        assertEq(stored.token, address(bwlk), "stored token");
        assertEq(stored.currency, address(0), "stored currency");
        assertEq(stored.migrationBlock, cfg.migrationBlock, "stored migrationBlock");
        assertEq(
            stored.reservedTokenAmountForLP,
            uint128(EthereumConfig.CCA_BUCKET - EthereumConfig.CCA_AUCTION_SUPPLY),
            "stored LP reserve"
        );
        assertEq(stored.recipient, treasury, "stored recipient");
        assertEq(stored.positionRecipient, address(locker), "stored positionRecipient");
        assertEq(stored.poolParameters.fee, EthereumConfig.POOL_FEE, "stored pool fee");
        assertEq(stored.poolParameters.tickSpacing, EthereumConfig.POOL_TICK_SPACING, "stored pool tickSpacing");
        assertEq(stored.poolParameters.hook, address(0), "stored hookless");

        // -- Bid enough to graduate (auction live, clock inside the bidding window) --
        vm.roll(cfg.startBlock + 1);
        vm.deal(bidder, 1 ether);
        uint256 maxPrice = FLOOR_Q96 + 2 * TICK_Q96; // tick-aligned, above the floor/clearing price
        vm.prank(bidder);
        ICcaAuctionLive(auction).submitBid{value: BID_AMOUNT}(maxPrice, uint128(BID_AMOUNT), bidder, "");

        // -- Migrate (permissionless; sweeps the raise, initializes the pool, mints LP to locker) --
        vm.roll(cfg.migrationBlock + 1);
        uint256 treasuryBwlkBefore = bwlk.balanceOf(treasury);
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
            assertEq(key.currency1, address(bwlk), "pool currency1 is BWLK");
            assertEq(key.fee, EthereumConfig.POOL_FEE, "pool fee");
            assertEq(key.tickSpacing, EthereumConfig.POOL_TICK_SPACING, "pool tickSpacing");
            assertEq(key.hooks, address(0), "hookless pool (not front-run)");
            assertGt(pm.getPositionLiquidity(tokenIds[i]), 0, "position has liquidity");
        }

        // The ETH side is the binding LP budget at these prices, so most of the 219,466 BWLK reserve
        // returns to the treasury recipient.
        assertGt(bwlk.balanceOf(treasury), treasuryBwlkBefore, "unused LP reserve swept to recipient");

        // -- Post-migrate governance wiring (script 06's printed step 2/3) --
        voter.setPoolHooks(address(0)); // the one-shot hook commit, hookless as read from the pool
        for (uint256 i = 0; i < mintCount; i++) {
            vm.prank(registrar);
            locker.registerPosition(tokenIds[i]);
        }
        assertEq(locker.getLockedPositions().length, mintCount, "every minted position locked");
        vm.prank(registrar);
        locker.renounceRegistrar();
        assertEq(locker.registrar(), address(0), "registrar renounced");

        // -- Burn the unsold supply (script 06's printed step 4) --
        uint256 auctionBalance = bwlk.balanceOf(auction);
        uint256 deadBefore = bwlk.balanceOf(DEAD);
        burner.sweep(auction);
        uint256 deadDelta = bwlk.balanceOf(DEAD) - deadBefore;
        assertGt(deadDelta, 0, "unsold supply burned");
        assertLt(deadDelta, EthereumConfig.CCA_AUCTION_SUPPLY, "partial sale: sold tokens stay claimable");
        assertEq(deadDelta + bwlk.balanceOf(auction), auctionBalance, "burn accounts for exactly the unsold part");
        assertEq(bwlk.balanceOf(address(burner)), 0, "burner holds nothing");
        assertTrue(ICcaAuctionLive(auction).sweepUnsoldTokensBlock() != 0, "auction marked swept");
    }
}

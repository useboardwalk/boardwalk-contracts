// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BWLK} from "src/token/BWLK.sol";
import {BwlkMigration} from "src/token/BwlkMigration.sol";
import {UnsoldBurner} from "src/token/UnsoldBurner.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {ParticipationDistributor} from "src/governance/ParticipationDistributor.sol";
import {IV4PositionManager} from "src/interfaces/IV4PositionManager.sol";
import {AssertBwlkDeploy} from "script/bwlk/04_AssertBwlkDeploy.s.sol";
import {EthereumConfig} from "script/bwlk/EthereumConfig.sol";
import {
    MockRewardTrackerFull,
    MockRewardDistributor,
    MockBnToken,
    MockMintableERC20
} from "test/bwlk/MockMorphexStaking.sol";
import {MockCcaAuction} from "test/bwlk/UnsoldBurnerMocks.sol";

/// @dev Minimal v4 PositionManager double: just enough for the locker's registration path.
contract MockPmForGate {
    mapping(uint256 => address) public ownerOf;
    IV4PositionManager.PoolKey internal key;

    constructor(
        IV4PositionManager.PoolKey memory _key
    ) {
        key = _key;
    }

    function mint(
        address to,
        uint256 id
    ) external {
        ownerOf[id] = to;
    }

    function getPoolAndPositionInfo(
        uint256
    ) external view returns (IV4PositionManager.PoolKey memory, uint256) {
        return (key, 0);
    }
}

/// @title BwlkDeployAssertionTest
/// @notice Non-fork coverage of the go-live gate `AssertBwlkDeploy.assertAll`: a correctly wired
///         deployment passes, and breaking any single D-1..D-5 / F-1 / readiness invariant reverts with
///         the matching error. Uses BWLK staking doubles so the wiring checks run against real state.
contract BwlkDeployAssertionTest is Test {
    AssertBwlkDeploy internal gate;

    BWLK internal bwlk;
    MockMintableERC20 internal bmx;
    MockRewardTrackerFull internal staked;
    MockRewardTrackerFull internal bonus;
    MockRewardTrackerFull internal fee;
    MockBnToken internal bnBwlk;
    GovernanceVoter internal voter;
    BwlkMigration internal migrator;
    LPLocker internal lpLocker;
    UnsoldBurner internal burner;
    MockCcaAuction internal auction;
    MockPmForGate internal pm;

    address internal escrow = makeAddr("escrow");
    address internal timelock = makeAddr("timelock");
    address internal keeper = makeAddr("keeper");
    address internal lpRegistrar = makeAddr("lpRegistrar");
    uint256 internal deadline;

    function setUp() public {
        gate = new AssertBwlkDeploy();
        deadline = block.timestamp + 365 days;
        // The gate requires the timelock to be a contract (an EOA gives no delay).
        vm.etch(timelock, hex"00");

        // BWLK minted to escrow; escrow funds the migration pool.
        vm.prank(escrow);
        bwlk = new BWLK(escrow, makeAddr("ccipAdmin"));

        bmx = new MockMintableERC20("BMX", "BMX");
        pm = new MockPmForGate(
            IV4PositionManager.PoolKey({
                currency0: address(0),
                currency1: address(bwlk),
                fee: EthereumConfig.POOL_FEE,
                tickSpacing: EthereumConfig.POOL_TICK_SPACING,
                hooks: address(0)
            })
        );
        staked = new MockRewardTrackerFull("Staked BWLK", "sBWLK");
        bonus = new MockRewardTrackerFull("Bonus BWLK", "snBWLK");
        fee = new MockRewardTrackerFull("Staked + Bonus + Fee BWLK", "sbfBWLK");
        bnBwlk = new MockBnToken("Bonus BWLK", "bnBWLK");

        // One-shot initialize each tracker with a distributor wired back to it (gate D-3).
        staked.initialize(address(new MockRewardDistributor(address(staked))));
        bonus.initialize(address(new MockRewardDistributor(address(bonus))));
        fee.initialize(address(new MockRewardDistributor(address(fee))));

        // Both private modes on, mirroring live Base (gate D-3).
        staked.setInPrivateTransferMode(true);
        staked.setInPrivateStakingMode(true);
        bonus.setInPrivateTransferMode(true);
        bonus.setInPrivateStakingMode(true);
        fee.setInPrivateTransferMode(true);
        fee.setInPrivateStakingMode(true);

        voter = new GovernanceVoter(
            address(this),
            GovernanceVoter.DeployParams({
                sbfBmx: address(fee),
                stakedBmxTracker: address(staked),
                bnBmx: address(bnBwlk),
                bmx: address(bwlk),
                weth: makeAddr("weth"),
                universalRouter: makeAddr("router"),
                v4PositionManager: address(pm),
                treasury: makeAddr("treasury"),
                fallbackTreasury: makeAddr("fallback"),
                epochZero: block.timestamp,
                epochDuration: 7 days,
                poolFee: EthereumConfig.POOL_FEE,
                poolTickSpacing: EthereumConfig.POOL_TICK_SPACING,
                poolHooks: address(0),
                keeper: keeper
            })
        );

        migrator = new BwlkMigration(
            timelock,
            address(bmx),
            address(bwlk),
            address(staked),
            address(bonus),
            address(fee),
            address(bnBwlk),
            address(voter),
            deadline
        );

        // Fund the pool and set the one-shot root (owner = timelock).
        vm.prank(escrow);
        IERC20(address(bwlk)).transfer(address(migrator), EthereumConfig.MIGRATION_POOL);
        vm.prank(timelock);
        migrator.setMerkleRoot(keccak256("root"));

        _wireStakingForMigrator();

        // Post-launch wiring the gate's A-section checks: hook committed, locker wired as the
        // voter's registered peer with the launch position registered + registrar renounced,
        // burner + auction bound to this BWLK with the auction bucket offered.
        voter.setPoolHooks(address(0));
        lpLocker = new LPLocker(address(pm), address(voter), address(0), address(bwlk), lpRegistrar);
        ParticipationDistributor pd = new ParticipationDistributor(address(bwlk), address(voter));
        voter.initializePeers(address(lpLocker), address(pd), makeAddr("feeCollector"));
        pm.mint(address(lpLocker), 1);
        vm.prank(lpRegistrar);
        lpLocker.registerPosition(1);
        vm.prank(lpRegistrar);
        lpLocker.renounceRegistrar();
        burner = new UnsoldBurner(address(bwlk));
        auction = new MockCcaAuction(IERC20(address(bwlk)), address(burner));
        auction.setTotalSupply(uint128(EthereumConfig.CCA_AUCTION_SUPPLY));
    }

    /// @dev Grant the deploy-time roles + tracker wiring the go-live gate expects (this contract is the
    ///      mocks' gov).
    function _wireStakingForMigrator() internal {
        staked.setHandler(address(migrator), true);
        bonus.setHandler(address(migrator), true);
        fee.setHandler(address(migrator), true);
        bnBwlk.setMinter(address(migrator), true);

        // Tiers pull the prior tier's token via the handler bypass.
        staked.setHandler(address(bonus), true);
        bonus.setHandler(address(fee), true);

        staked.setDepositToken(address(bwlk), true);
        bonus.setDepositToken(address(staked), true);
        fee.setDepositToken(address(bonus), true);
        fee.setDepositToken(address(bnBwlk), true);
    }

    /// @dev Grant the migrator's own handler/minter roles (the tier cross-wiring + deposit tokens are
    ///      global on the trackers, already set in setUp).
    function _wireMigrator(
        address m
    ) internal {
        staked.setHandler(m, true);
        bonus.setHandler(m, true);
        fee.setHandler(m, true);
        bnBwlk.setMinter(m, true);
    }

    function _cfg() internal view returns (AssertBwlkDeploy.Config memory) {
        return AssertBwlkDeploy.Config({
            migrator: address(migrator),
            voter: address(voter),
            bwlk: address(bwlk),
            bmx: address(bmx),
            stakedBwlkTracker: address(staked),
            bonusBwlkTracker: address(bonus),
            feeBwlkTracker: address(fee),
            bnBwlk: address(bnBwlk),
            timelock: timelock,
            stakingGov: address(this),
            auction: address(auction),
            burner: address(burner),
            lpLocker: address(lpLocker),
            totalMigratableBmx: EthereumConfig.MIGRATION_POOL,
            expectedTrackerCodehash: address(staked).codehash,
            expectedBnTokenCodehash: address(bnBwlk).codehash,
            bmxEmissionsHaltedAttested: true,
            bmxStandardAttested: true
        });
    }

    // ---------- happy path ----------

    function test_AssertAll_PassesOnCorrectlyWiredDeploy() public view {
        gate.assertAll(_cfg());
    }

    // ---------- D-1 ----------

    function test_RevertWhen_D1_PoolUndersized() public {
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.totalMigratableBmx = EthereumConfig.MIGRATION_POOL + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwlkDeploy.D1_PoolUndersized.selector, EthereumConfig.MIGRATION_POOL, cfg.totalMigratableBmx
            )
        );
        gate.assertAll(cfg);
    }

    function test_RevertWhen_D1_EmissionsNotAttested() public {
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.bmxEmissionsHaltedAttested = false;
        vm.expectRevert(AssertBwlkDeploy.D1_EmissionsNotAttested.selector);
        gate.assertAll(cfg);
    }

    // ---------- D-2 ----------

    function test_RevertWhen_D2_FeeTrackerMismatch() public {
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.feeBwlkTracker = makeAddr("notFee");
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwlkDeploy.D2_VoterFeeTrackerMismatch.selector, address(fee), cfg.feeBwlkTracker
            )
        );
        gate.assertAll(cfg);
    }

    function test_RevertWhen_D2_StakedTrackerMismatch() public {
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.stakedBwlkTracker = makeAddr("notStaked");
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwlkDeploy.D2_StakedTrackerMismatch.selector, address(staked), cfg.stakedBwlkTracker
            )
        );
        gate.assertAll(cfg);
    }

    function test_RevertWhen_D2_BnTokenMismatch() public {
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.bnBwlk = makeAddr("notBn");
        vm.expectRevert(
            abi.encodeWithSelector(AssertBwlkDeploy.D2_BnTokenMismatch.selector, address(bnBwlk), cfg.bnBwlk)
        );
        gate.assertAll(cfg);
    }

    function test_RevertWhen_D2_BonusTrackerMismatch() public {
        // The migrator's bonus immutable is anchored only here; a config pointing elsewhere is caught.
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.bonusBwlkTracker = makeAddr("notBonus");
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwlkDeploy.D2_BonusTrackerMismatch.selector, address(bonus), cfg.bonusBwlkTracker
            )
        );
        gate.assertAll(cfg);
    }

    function test_RevertWhen_D2_BmxMismatch() public {
        // The token D-5 attests must be the one the migrator surrenders.
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.bmx = makeAddr("otherBmx");
        vm.expectRevert(abi.encodeWithSelector(AssertBwlkDeploy.D2_BmxMismatch.selector, address(bmx), cfg.bmx));
        gate.assertAll(cfg);
    }

    function test_RevertWhen_D2_TrackersNotDistinct() public {
        // A migrator built with an aliased bonus tier (bonus == staked) is rejected.
        BwlkMigration aliased = new BwlkMigration(
            timelock,
            address(bmx),
            address(bwlk),
            address(staked),
            address(staked), // bonus aliases staked
            address(fee),
            address(bnBwlk),
            address(voter),
            deadline
        );
        deal(address(bwlk), address(aliased), EthereumConfig.MIGRATION_POOL);
        vm.prank(timelock);
        aliased.setMerkleRoot(keccak256("root"));

        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.migrator = address(aliased);
        cfg.bonusBwlkTracker = address(staked);
        vm.expectRevert(AssertBwlkDeploy.D2_TrackersNotDistinct.selector);
        gate.assertAll(cfg);
    }

    // ---------- D-3 ----------

    function test_RevertWhen_D3_MigratorNotHandler() public {
        staked.setHandler(address(migrator), false);
        vm.expectRevert(abi.encodeWithSelector(AssertBwlkDeploy.D3_MigratorNotHandler.selector, address(staked)));
        gate.assertAll(_cfg());
    }

    function test_RevertWhen_D3_MigratorNotMinter() public {
        bnBwlk.setMinter(address(migrator), false);
        vm.expectRevert(abi.encodeWithSelector(AssertBwlkDeploy.D3_MigratorNotMinter.selector, address(bnBwlk)));
        gate.assertAll(_cfg());
    }

    function test_RevertWhen_D3_TrackerNotWired() public {
        staked.setHandler(address(bonus), false);
        vm.expectRevert(
            abi.encodeWithSelector(AssertBwlkDeploy.D3_TrackerNotWired.selector, address(staked), address(bonus))
        );
        gate.assertAll(_cfg());
    }

    function test_RevertWhen_D3_DepositTokenUnset() public {
        fee.setDepositToken(address(bnBwlk), false);
        vm.expectRevert(
            abi.encodeWithSelector(AssertBwlkDeploy.D3_DepositTokenUnset.selector, address(fee), address(bnBwlk))
        );
        gate.assertAll(_cfg());
    }

    function test_RevertWhen_D3_FeeTrackerNotBnHandler() public {
        // Put bnBWLK in private transfer mode without making the fee tracker a handler on it.
        bnBwlk.setInPrivateTransferMode(true);
        vm.expectRevert(
            abi.encodeWithSelector(AssertBwlkDeploy.D3_FeeTrackerNotBnHandler.selector, address(bnBwlk), address(fee))
        );
        gate.assertAll(_cfg());
        // Wiring the fee tracker as a handler clears it.
        bnBwlk.setHandler(address(fee), true);
        gate.assertAll(_cfg());
    }

    /// @dev Deploy a migrator around a FRESH bonus tracker — the only tier not pinned by the voter's
    ///      immutables — fully wired except the fresh tracker's initialize() state, so the D-3
    ///      distributor checks can be exercised without redeploying the voter.
    function _stackWithFreshBonus()
        internal
        returns (MockRewardTrackerFull freshBonus, AssertBwlkDeploy.Config memory cfg)
    {
        freshBonus = new MockRewardTrackerFull("Bonus BWLK", "snBWLK");
        BwlkMigration m = new BwlkMigration(
            timelock,
            address(bmx),
            address(bwlk),
            address(staked),
            address(freshBonus),
            address(fee),
            address(bnBwlk),
            address(voter),
            deadline
        );
        deal(address(bwlk), address(m), EthereumConfig.MIGRATION_POOL);
        vm.prank(timelock);
        m.setMerkleRoot(keccak256("root"));
        _wireMigrator(address(m));
        freshBonus.setHandler(address(m), true);
        staked.setHandler(address(freshBonus), true);
        freshBonus.setHandler(address(fee), true);
        freshBonus.setDepositToken(address(staked), true);
        fee.setDepositToken(address(freshBonus), true);

        cfg = _cfg();
        cfg.migrator = address(m);
        cfg.bonusBwlkTracker = address(freshBonus);
    }

    function test_RevertWhen_D3_TrackerNotInitialized() public {
        (MockRewardTrackerFull freshBonus, AssertBwlkDeploy.Config memory cfg) = _stackWithFreshBonus();
        vm.expectRevert(abi.encodeWithSelector(AssertBwlkDeploy.D3_TrackerNotInitialized.selector, address(freshBonus)));
        gate.assertAll(cfg);
    }

    function test_RevertWhen_D3_DistributorMismatch() public {
        (MockRewardTrackerFull freshBonus, AssertBwlkDeploy.Config memory cfg) = _stackWithFreshBonus();
        // Initialized, but the distributor's back-pointer targets the wrong tracker.
        freshBonus.initialize(address(new MockRewardDistributor(address(staked))));
        address dist = freshBonus.distributor();
        vm.expectRevert(
            abi.encodeWithSelector(AssertBwlkDeploy.D3_DistributorMismatch.selector, address(freshBonus), dist)
        );
        gate.assertAll(cfg);
    }

    // ---------- D-4 ----------

    function test_RevertWhen_D4_TrackerCodehashMismatch() public {
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.expectedTrackerCodehash = keccak256("not-the-tracker");
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwlkDeploy.D4_TrackerCodehashMismatch.selector,
                address(staked),
                address(staked).codehash,
                cfg.expectedTrackerCodehash
            )
        );
        gate.assertAll(cfg);
    }

    function test_RevertWhen_D5_BmxNoCode() public {
        // D-5 reuses D4_NoCode for a BMX address with no contract code. D-2 now requires
        // migrator.BMX() == cfg.bmx, so reaching this branch means the migrator itself was built with a
        // no-code BMX (caught here rather than silently surrendering to a dead address).
        address eoaBmx = makeAddr("eoaNoCodeBmx");
        BwlkMigration m = new BwlkMigration(
            timelock,
            eoaBmx,
            address(bwlk),
            address(staked),
            address(bonus),
            address(fee),
            address(bnBwlk),
            address(voter),
            deadline
        );
        deal(address(bwlk), address(m), EthereumConfig.MIGRATION_POOL);
        _wireMigrator(address(m));
        vm.prank(timelock);
        m.setMerkleRoot(keccak256("root"));

        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.migrator = address(m);
        cfg.bmx = eoaBmx;
        vm.expectRevert(abi.encodeWithSelector(AssertBwlkDeploy.D4_NoCode.selector, eoaBmx));
        gate.assertAll(cfg);
    }

    function test_RevertWhen_D4_BnTokenCodehashMismatch() public {
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.expectedBnTokenCodehash = keccak256("not-the-bn-token");
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwlkDeploy.D4_BnTokenCodehashMismatch.selector,
                address(bnBwlk),
                address(bnBwlk).codehash,
                cfg.expectedBnTokenCodehash
            )
        );
        gate.assertAll(cfg);
    }

    function test_D4_SkipsBnTokenCheckWhenExpectedZero() public view {
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.expectedBnTokenCodehash = bytes32(0); // opt out of the bnBWLK byte-match
        gate.assertAll(cfg);
    }

    // ---------- D-5 ----------

    function test_RevertWhen_D5_BmxNotAttested() public {
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.bmxStandardAttested = false;
        vm.expectRevert(AssertBwlkDeploy.D5_BmxNotAttested.selector);
        gate.assertAll(cfg);
    }

    // ---------- F-1 / readiness ----------

    function test_RevertWhen_F1_OwnerNotTimelock() public {
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.timelock = makeAddr("notTimelock");
        vm.expectRevert(abi.encodeWithSelector(AssertBwlkDeploy.F1_OwnerNotTimelock.selector, timelock, cfg.timelock));
        gate.assertAll(cfg);
    }

    function test_RevertWhen_F1_StakingGovNotExpected_Tracker() public {
        address hotkey = makeAddr("hotkey");
        staked.setGov(hotkey);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwlkDeploy.F1_StakingGovNotExpected.selector, address(staked), hotkey, address(this)
            )
        );
        gate.assertAll(_cfg());
    }

    function test_RevertWhen_F1_StakingGovNotExpected_BnToken() public {
        address hotkey = makeAddr("hotkey");
        bnBwlk.setGov(hotkey);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwlkDeploy.F1_StakingGovNotExpected.selector, address(bnBwlk), hotkey, address(this)
            )
        );
        gate.assertAll(_cfg());
    }

    function test_RevertWhen_D1_ZeroMigratable() public {
        // A zeroed env would make the pool-sufficiency check vacuously true.
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.totalMigratableBmx = 0;
        vm.expectRevert(AssertBwlkDeploy.D1_ZeroMigratable.selector);
        gate.assertAll(cfg);
    }

    function test_RevertWhen_D2_BwlkSupplyWrong() public {
        // A self-consistent stack built on a wrong-shape token fails the supply anchor.
        bmx.mint(address(migrator), EthereumConfig.MIGRATION_POOL); // pass D-1 in the wrong token
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.bwlk = address(bmx);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwlkDeploy.D2_BwlkSupplyWrong.selector, EthereumConfig.MIGRATION_POOL, EthereumConfig.TOTAL_SUPPLY
            )
        );
        gate.assertAll(cfg);
    }

    function test_RevertWhen_D3_TrackerPrivateModeOff() public {
        staked.setInPrivateTransferMode(false);
        vm.expectRevert(abi.encodeWithSelector(AssertBwlkDeploy.D3_TrackerPrivateModeOff.selector, address(staked)));
        gate.assertAll(_cfg());
    }

    function test_RevertWhen_F1_TimelockHasNoCode() public {
        // An EOA satisfies the owner equality but provides no delay.
        address eoaOwner = makeAddr("eoaOwner");
        BwlkMigration m = new BwlkMigration(
            eoaOwner,
            address(bmx),
            address(bwlk),
            address(staked),
            address(bonus),
            address(fee),
            address(bnBwlk),
            address(voter),
            deadline
        );
        deal(address(bwlk), address(m), EthereumConfig.MIGRATION_POOL);
        _wireMigrator(address(m));
        vm.prank(eoaOwner);
        m.setMerkleRoot(keccak256("root"));

        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.migrator = address(m);
        cfg.timelock = eoaOwner;
        vm.expectRevert(abi.encodeWithSelector(AssertBwlkDeploy.F1_TimelockHasNoCode.selector, eoaOwner));
        gate.assertAll(cfg);
    }

    function test_RevertWhen_GoLive_ClaimWindowImplausible() public {
        // A stale dry-run deadline (a week out) passes a bare >= now check but not the window floor.
        BwlkMigration m = new BwlkMigration(
            timelock,
            address(bmx),
            address(bwlk),
            address(staked),
            address(bonus),
            address(fee),
            address(bnBwlk),
            address(voter),
            block.timestamp + 7 days
        );
        deal(address(bwlk), address(m), EthereumConfig.MIGRATION_POOL);
        _wireMigrator(address(m));
        vm.prank(timelock);
        m.setMerkleRoot(keccak256("root"));

        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.migrator = address(m);
        vm.expectRevert(
            abi.encodeWithSelector(AssertBwlkDeploy.GoLive_ClaimWindowImplausible.selector, block.timestamp + 7 days)
        );
        gate.assertAll(cfg);
    }

    // ---------- A (CCA launch wiring) ----------

    function test_AssertAll_SkipsCcaSectionWhenUnset() public {
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.auction = address(0);
        cfg.burner = address(0);
        cfg.lpLocker = address(0);
        gate.assertAll(cfg); // pre-launch dry run still passes D-1..D-5/F-1
    }

    function test_RevertWhen_A1_AuctionTokenMismatch() public {
        MockCcaAuction wrongTokenAuction = new MockCcaAuction(IERC20(address(bmx)), address(burner));
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.auction = address(wrongTokenAuction);
        vm.expectRevert(
            abi.encodeWithSelector(AssertBwlkDeploy.A1_AuctionTokenMismatch.selector, address(bmx), address(bwlk))
        );
        gate.assertAll(cfg);
    }

    function test_RevertWhen_A2_TokensRecipientNotBurner() public {
        address launchWallet = makeAddr("launchWallet"); // the web-UI default this check exists for
        MockCcaAuction walletAuction = new MockCcaAuction(IERC20(address(bwlk)), launchWallet);
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.auction = address(walletAuction);
        vm.expectRevert(
            abi.encodeWithSelector(AssertBwlkDeploy.A2_TokensRecipientNotBurner.selector, launchWallet, address(burner))
        );
        gate.assertAll(cfg);
    }

    function test_RevertWhen_A3_BurnerBwlkMismatch() public {
        UnsoldBurner wrongBurner = new UnsoldBurner(address(bmx));
        MockCcaAuction a = new MockCcaAuction(IERC20(address(bwlk)), address(wrongBurner));
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.auction = address(a);
        cfg.burner = address(wrongBurner);
        vm.expectRevert(
            abi.encodeWithSelector(AssertBwlkDeploy.A3_BurnerBwlkMismatch.selector, address(bmx), address(bwlk))
        );
        gate.assertAll(cfg);
    }

    function test_RevertWhen_A4_AuctionSupplyUnexpected() public {
        auction.setTotalSupply(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwlkDeploy.A4_AuctionSupplyUnexpected.selector, 1, EthereumConfig.CCA_AUCTION_SUPPLY
            )
        );
        gate.assertAll(_cfg());
    }

    function test_RevertWhen_A5_PoolHooksNotCommitted() public {
        // A stack whose voter never committed the hook fails the A-section.
        GovernanceVoter voter2 = new GovernanceVoter(
            address(this),
            GovernanceVoter.DeployParams({
                sbfBmx: address(fee),
                stakedBmxTracker: address(staked),
                bnBmx: address(bnBwlk),
                bmx: address(bwlk),
                weth: makeAddr("weth"),
                universalRouter: makeAddr("router"),
                v4PositionManager: makeAddr("pm"),
                treasury: makeAddr("treasury"),
                fallbackTreasury: makeAddr("fallback"),
                epochZero: block.timestamp,
                epochDuration: 7 days,
                poolFee: EthereumConfig.POOL_FEE,
                poolTickSpacing: EthereumConfig.POOL_TICK_SPACING,
                poolHooks: address(0),
                keeper: keeper
            })
        );
        BwlkMigration m = new BwlkMigration(
            timelock,
            address(bmx),
            address(bwlk),
            address(staked),
            address(bonus),
            address(fee),
            address(bnBwlk),
            address(voter2),
            deadline
        );
        deal(address(bwlk), address(m), EthereumConfig.MIGRATION_POOL);
        _wireMigrator(address(m));
        vm.prank(timelock);
        m.setMerkleRoot(keccak256("root"));
        LPLocker locker2 = new LPLocker(makeAddr("pm"), address(voter2), address(0), address(bwlk), lpRegistrar);
        vm.prank(lpRegistrar);
        locker2.renounceRegistrar();

        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.voter = address(voter2);
        cfg.migrator = address(m);
        cfg.lpLocker = address(locker2);
        vm.expectRevert(AssertBwlkDeploy.A5_PoolHooksNotCommitted.selector);
        gate.assertAll(cfg);
    }

    function test_RevertWhen_A6_RegistrarNotRenounced() public {
        LPLocker lockerNR = new LPLocker(makeAddr("pm"), address(voter), address(0), address(bwlk), lpRegistrar);
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.lpLocker = address(lockerNR);
        vm.expectRevert(abi.encodeWithSelector(AssertBwlkDeploy.A6_RegistrarNotRenounced.selector, lpRegistrar));
        gate.assertAll(cfg);
    }

    function test_RevertWhen_A7_LockerWiringMismatch() public {
        // Locker bound to the wrong currency1.
        LPLocker lockerWrong = new LPLocker(makeAddr("pm"), address(voter), address(0), address(bmx), lpRegistrar);
        vm.prank(lpRegistrar);
        lockerWrong.renounceRegistrar();
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.lpLocker = address(lockerWrong);
        vm.expectRevert(AssertBwlkDeploy.A7_LockerWiringMismatch.selector);
        gate.assertAll(cfg);
    }

    function test_RevertWhen_A7_LockerPositionManagerMismatch() public {
        // Locker bound to a different PositionManager than the voter mints/claims through.
        LPLocker lockerWrongPm =
            new LPLocker(makeAddr("otherPm"), address(voter), address(0), address(bwlk), lpRegistrar);
        vm.prank(lpRegistrar);
        lockerWrongPm.renounceRegistrar();
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.lpLocker = address(lockerWrongPm);
        vm.expectRevert(AssertBwlkDeploy.A7_LockerWiringMismatch.selector);
        gate.assertAll(cfg);
    }

    function test_RevertWhen_A8_LockerNotVoterPeer() public {
        // A perfectly-wired locker that is NOT the voter's registered peer still fails: option-3
        // locks and revenue routing hang off initializePeers.
        LPLocker lockerNotPeer = new LPLocker(address(pm), address(voter), address(0), address(bwlk), lpRegistrar);
        vm.prank(lpRegistrar);
        lockerNotPeer.renounceRegistrar();
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.lpLocker = address(lockerNotPeer);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwlkDeploy.A8_LockerNotVoterPeer.selector, address(lpLocker), address(lockerNotPeer)
            )
        );
        gate.assertAll(cfg);
    }

    function test_RevertWhen_A9_NoPositionsRegistered() public {
        // A fully-wired stack whose registrar renounced WITHOUT registering the launch position:
        // the fees of every unregistered position are unclaimable forever.
        GovernanceVoter voter2 = new GovernanceVoter(
            address(this),
            GovernanceVoter.DeployParams({
                sbfBmx: address(fee),
                stakedBmxTracker: address(staked),
                bnBmx: address(bnBwlk),
                bmx: address(bwlk),
                weth: makeAddr("weth"),
                universalRouter: makeAddr("router"),
                v4PositionManager: address(pm),
                treasury: makeAddr("treasury"),
                fallbackTreasury: makeAddr("fallback"),
                epochZero: block.timestamp,
                epochDuration: 7 days,
                poolFee: EthereumConfig.POOL_FEE,
                poolTickSpacing: EthereumConfig.POOL_TICK_SPACING,
                poolHooks: address(0),
                keeper: keeper
            })
        );
        voter2.setPoolHooks(address(0));
        BwlkMigration m = new BwlkMigration(
            timelock,
            address(bmx),
            address(bwlk),
            address(staked),
            address(bonus),
            address(fee),
            address(bnBwlk),
            address(voter2),
            deadline
        );
        deal(address(bwlk), address(m), EthereumConfig.MIGRATION_POOL);
        _wireMigrator(address(m));
        vm.prank(timelock);
        m.setMerkleRoot(keccak256("root"));
        LPLocker locker2 = new LPLocker(address(pm), address(voter2), address(0), address(bwlk), lpRegistrar);
        ParticipationDistributor pd2 = new ParticipationDistributor(address(bwlk), address(voter2));
        voter2.initializePeers(address(locker2), address(pd2), makeAddr("feeCollector"));
        vm.prank(lpRegistrar);
        locker2.renounceRegistrar();

        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.voter = address(voter2);
        cfg.migrator = address(m);
        cfg.lpLocker = address(locker2);
        vm.expectRevert(AssertBwlkDeploy.A9_NoPositionsRegistered.selector);
        gate.assertAll(cfg);
    }

    function test_RevertWhen_GoLive_RootNotSet() public {
        // A fresh migrator wired identically but with no root set fails the readiness gate.
        BwlkMigration unrooted = new BwlkMigration(
            timelock,
            address(bmx),
            address(bwlk),
            address(staked),
            address(bonus),
            address(fee),
            address(bnBwlk),
            address(voter),
            deadline
        );
        deal(address(bwlk), address(unrooted), EthereumConfig.MIGRATION_POOL);
        _wireMigrator(address(unrooted));

        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.migrator = address(unrooted);
        vm.expectRevert(AssertBwlkDeploy.GoLive_RootNotSet.selector);
        gate.assertAll(cfg);
    }

    function test_RevertWhen_GoLive_ClaimWindowClosed() public {
        uint256 dl = migrator.CLAIM_DEADLINE();
        vm.warp(dl + 1);
        vm.expectRevert(abi.encodeWithSelector(AssertBwlkDeploy.GoLive_ClaimWindowClosed.selector, dl, dl + 1));
        gate.assertAll(_cfg());
    }
}

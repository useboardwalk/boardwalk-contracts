// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BWS} from "src/token/BWS.sol";
import {BwsMigration} from "src/token/BwsMigration.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {ParticipationDistributor} from "src/governance/ParticipationDistributor.sol";
import {AssertBwsDeploy} from "script/bws/04_AssertBwsDeploy.s.sol";
import {ArbitrumConfig} from "script/bws/ArbitrumConfig.sol";
import {MockRewardTrackerFull, MockRewardDistributor, MockBnToken} from "test/bws/MockMorphexStaking.sol";

/// @title BwsArbitrumDeployForkTest
/// @notice BWS migration deploy + go-live gate on an Arbitrum One fork, against real Uniswap v4 infra
///         (WETH / UniversalRouter / PositionManager) and the legacy BMX token. The BWS staking
///         trackers + bnBWS are not deployed yet (a separate 0.6.12 repo), so doubles stand in for them;
///         everything else is production code. Covers: the stack deploys and wires end-to-end;
///         `AssertBwsDeploy.assertAll` passes on the wired deployment and reverts on injected violations;
///         Arbitrum BMX is a non-fee-on-transfer ERC20 (D-5).
///
/// @dev Run: forge test --match-contract BwsArbitrumDeployForkTest --fork-url https://arb1.arbitrum.io/rpc
///      (also self-forks via ARBITRUM_RPC_URL when run without --fork-url).
contract BwsArbitrumDeployForkTest is Test {
    AssertBwsDeploy internal gate;

    BWS internal bws;
    MockRewardTrackerFull internal staked;
    MockRewardTrackerFull internal bonus;
    MockRewardTrackerFull internal fee;
    MockBnToken internal bnBws;
    GovernanceVoter internal voter;
    LPLocker internal lpLocker;
    ParticipationDistributor internal pd;
    BwsMigration internal migrator;

    address internal constant BMX = ArbitrumConfig.ARB_BMX;
    address internal escrow = makeAddr("escrow");
    address internal timelock = makeAddr("timelock");
    address internal keeper = makeAddr("keeper");
    address internal feeCollector = makeAddr("feeCollector");
    address internal lpRegistrar = makeAddr("lpRegistrar");
    uint256 internal deadline;

    bool internal forked;

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function setUp() public {
        // Run with --fork-url, or self-fork from ARBITRUM_RPC_URL; without either the suite skips
        // (CI runs with no RPC configured).
        if (ArbitrumConfig.ARB_WETH.code.length == 0) {
            string memory rpcUrl = vm.envOr("ARBITRUM_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) return;
            vm.createSelectFork(rpcUrl);
        }
        forked = true;
        require(BMX.code.length > 0, "BMX missing on fork");

        gate = new AssertBwsDeploy();
        deadline = block.timestamp + 365 days;
        // The gate requires the timelock to be a contract (an EOA gives no delay).
        vm.etch(timelock, hex"00");

        // 1. BWS minted to escrow.
        vm.prank(escrow);
        bws = new BWS(escrow, makeAddr("ccipAdmin"));

        // 2. Staking doubles (real BWS staking trackers are deployed separately).
        staked = new MockRewardTrackerFull("Staked BWS", "sBWS");
        bonus = new MockRewardTrackerFull("Bonus BWS", "snBWS");
        fee = new MockRewardTrackerFull("Staked + Bonus + Fee BWS", "sbfBWS");
        bnBws = new MockBnToken("Bonus BWS", "bnBWS");
        staked.initialize(address(new MockRewardDistributor(address(staked))));
        bonus.initialize(address(new MockRewardDistributor(address(bonus))));
        fee.initialize(address(new MockRewardDistributor(address(fee))));
        staked.setInPrivateTransferMode(true);
        staked.setInPrivateStakingMode(true);
        bonus.setInPrivateTransferMode(true);
        bonus.setInPrivateStakingMode(true);
        fee.setInPrivateTransferMode(true);
        fee.setInPrivateStakingMode(true);

        // 3. Governance stack wired to real Arbitrum v4 infra.
        voter = new GovernanceVoter(
            address(this),
            GovernanceVoter.DeployParams({
                sbfBmx: address(fee),
                stakedBmxTracker: address(staked),
                bnBmx: address(bnBws),
                bmx: address(bws),
                weth: ArbitrumConfig.ARB_WETH,
                universalRouter: ArbitrumConfig.ARB_UNIVERSAL_ROUTER,
                v4PositionManager: ArbitrumConfig.ARB_POSITION_MANAGER,
                treasury: makeAddr("treasury"),
                fallbackTreasury: makeAddr("fallback"),
                epochZero: block.timestamp,
                epochDuration: 7 days,
                poolFee: ArbitrumConfig.POOL_FEE,
                poolTickSpacing: ArbitrumConfig.POOL_TICK_SPACING,
                poolHooks: address(0),
                keeper: keeper
            })
        );
        lpLocker =
            new LPLocker(ArbitrumConfig.ARB_POSITION_MANAGER, address(voter), address(0), address(bws), lpRegistrar);
        pd = new ParticipationDistributor(address(bws), address(voter));
        voter.initializePeers(address(lpLocker), address(pd), feeCollector);

        // Post-launch wiring the gate's A-section checks (hook committed, registrar renounced).
        voter.setPoolHooks(address(0));
        vm.prank(lpRegistrar);
        lpLocker.renounceRegistrar();

        // 4. Migrator owned by the timelock, funded, root set.
        migrator = new BwsMigration(
            timelock,
            BMX,
            address(bws),
            address(staked),
            address(bonus),
            address(fee),
            address(bnBws),
            address(voter),
            deadline
        );
        vm.prank(escrow);
        IERC20(address(bws)).transfer(address(migrator), ArbitrumConfig.MIGRATION_POOL);
        vm.prank(timelock);
        migrator.setMerkleRoot(keccak256("root"));

        // 5. BWS staking grants (runbook step, executed here by the doubles' gov = this test).
        staked.setHandler(address(migrator), true);
        bonus.setHandler(address(migrator), true);
        fee.setHandler(address(migrator), true);
        bnBws.setMinter(address(migrator), true);
        staked.setHandler(address(bonus), true);
        bonus.setHandler(address(fee), true);
        staked.setDepositToken(address(bws), true);
        bonus.setDepositToken(address(staked), true);
        fee.setDepositToken(address(bonus), true);
        fee.setDepositToken(address(bnBws), true);
    }

    function _cfg() internal view returns (AssertBwsDeploy.Config memory) {
        return AssertBwsDeploy.Config({
            migrator: address(migrator),
            voter: address(voter),
            bws: address(bws),
            bmx: BMX,
            stakedBwsTracker: address(staked),
            bonusBwsTracker: address(bonus),
            feeBwsTracker: address(fee),
            bnBws: address(bnBws),
            timelock: timelock,
            stakingGov: address(this),
            auction: address(0), // no live BWS auction on the fork; run() warns when skipped
            burner: address(0),
            lpLocker: address(lpLocker),
            totalMigratableBmx: ArbitrumConfig.MIGRATION_POOL,
            expectedTrackerCodehash: address(staked).codehash,
            expectedBnTokenCodehash: address(bnBws).codehash,
            bmxEmissionsHaltedAttested: true,
            bmxStandardAttested: true
        });
    }

    /// @notice The wired deployment passes the go-live gate against real Arbitrum infra + real BMX.
    function testFork_DeployAndAssert_Passes() public onlyFork {
        gate.assertAll(_cfg());
    }

    /// @notice D-5: the real Arbitrum BMX is a non-fee-on-transfer ERC20 (sender/receiver deltas equal).
    function testFork_BmxIsNonFeeOnTransfer() public onlyFork {
        address a = makeAddr("bmxHolderA");
        address b = makeAddr("bmxHolderB");
        uint256 amount = 1_000e18;
        deal(BMX, a, amount);

        uint256 aBefore = IERC20(BMX).balanceOf(a);
        uint256 bBefore = IERC20(BMX).balanceOf(b);
        vm.prank(a);
        IERC20(BMX).transfer(b, amount);

        assertEq(aBefore - IERC20(BMX).balanceOf(a), amount, "sender debited exactly amount");
        assertEq(IERC20(BMX).balanceOf(b) - bBefore, amount, "receiver credited exactly amount (no fee)");
        assertEq(IERC20Metadata(BMX).decimals(), 18, "BMX has 18 decimals");
    }

    /// @notice Injected D-1 violation reverts the gate on the fork.
    function testFork_AssertReverts_OnUndersizedPool() public onlyFork {
        AssertBwsDeploy.Config memory cfg = _cfg();
        cfg.totalMigratableBmx = ArbitrumConfig.MIGRATION_POOL + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwsDeploy.D1_PoolUndersized.selector, ArbitrumConfig.MIGRATION_POOL, cfg.totalMigratableBmx
            )
        );
        gate.assertAll(cfg);
    }

    /// @notice Injected D-3 violation (migrator loses its handler role) reverts the gate on the fork.
    function testFork_AssertReverts_OnMissingHandler() public onlyFork {
        fee.setHandler(address(migrator), false);
        vm.expectRevert(abi.encodeWithSelector(AssertBwsDeploy.D3_MigratorNotHandler.selector, address(fee)));
        gate.assertAll(_cfg());
    }
}

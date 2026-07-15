// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BWLK} from "src/token/BWLK.sol";
import {BwlkMigration} from "src/token/BwlkMigration.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {ParticipationDistributor} from "src/governance/ParticipationDistributor.sol";
import {AssertBwlkDeploy} from "script/bwlk/04_AssertBwlkDeploy.s.sol";
import {EthereumConfig} from "script/bwlk/EthereumConfig.sol";
import {MockRewardTrackerFull, MockRewardDistributor, MockBnToken} from "test/bwlk/MockMorphexStaking.sol";
import {MockERC20} from "test/bwlk/UnsoldBurnerMocks.sol";

/// @title BwlkEthereumDeployForkTest
/// @notice BWLK migration deploy + go-live gate on an Ethereum mainnet fork, against real Uniswap v4
///         infra (WETH / UniversalRouter / PositionManager). The BWLK staking trackers + bnBWLK are
///         not deployed yet (a separate 0.6.12 repo), so doubles stand in for them; everything else
///         is production code. Covers: the stack deploys and wires end-to-end;
///         `AssertBwlkDeploy.assertAll` passes on the wired deployment and reverts on injected
///         violations; the surrendered token is a non-fee-on-transfer ERC20 (D-5).
///
/// @dev The Ethereum-side migration source is still being re-scoped: pass BMX_ADDRESS to run the
///      D-5 transfer-delta proof against the real token; unset, an 18-dec mock stands in and the
///      real-token proof re-runs once the source is decided.
///      Run: forge test --match-contract BwlkEthereumDeployForkTest --fork-url https://ethereum-rpc.publicnode.com
///      (also self-forks via ETHEREUM_RPC_URL when run without --fork-url).
contract BwlkEthereumDeployForkTest is Test {
    AssertBwlkDeploy internal gate;

    BWLK internal bwlk;
    MockRewardTrackerFull internal staked;
    MockRewardTrackerFull internal bonus;
    MockRewardTrackerFull internal fee;
    MockBnToken internal bnBwlk;
    GovernanceVoter internal voter;
    LPLocker internal lpLocker;
    ParticipationDistributor internal pd;
    BwlkMigration internal migrator;

    address internal BMX;
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
        // Run with --fork-url, or self-fork from ETHEREUM_RPC_URL; without either the suite skips
        // (CI runs with no RPC configured).
        if (EthereumConfig.ETH_WETH.code.length == 0) {
            string memory rpcUrl = vm.envOr("ETHEREUM_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) return;
            vm.createSelectFork(rpcUrl);
        }
        forked = true;
        // Migration source: real token when BMX_ADDRESS is set AND live on this fork; an 18-dec
        // mock otherwise (also covers a stale env from the Arbitrum era).
        BMX = vm.envOr("BMX_ADDRESS", address(0));
        if (BMX.code.length == 0) BMX = address(new MockERC20("Legacy BMX", "BMX"));

        gate = new AssertBwlkDeploy();
        deadline = block.timestamp + 365 days;
        // The gate requires the timelock to be a contract (an EOA gives no delay).
        vm.etch(timelock, hex"00");

        // 1. BWLK minted to escrow.
        vm.prank(escrow);
        bwlk = new BWLK(escrow, makeAddr("ccipAdmin"));

        // 2. Staking doubles (real BWLK staking trackers are deployed separately).
        staked = new MockRewardTrackerFull("Staked BWLK", "sBWLK");
        bonus = new MockRewardTrackerFull("Bonus BWLK", "snBWLK");
        fee = new MockRewardTrackerFull("Staked + Bonus + Fee BWLK", "sbfBWLK");
        bnBwlk = new MockBnToken("Bonus BWLK", "bnBWLK");
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
                bnBmx: address(bnBwlk),
                bmx: address(bwlk),
                weth: EthereumConfig.ETH_WETH,
                universalRouter: EthereumConfig.ETH_UNIVERSAL_ROUTER,
                v4PositionManager: EthereumConfig.ETH_POSITION_MANAGER,
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
        lpLocker =
            new LPLocker(EthereumConfig.ETH_POSITION_MANAGER, address(voter), address(0), address(bwlk), lpRegistrar);
        pd = new ParticipationDistributor(address(bwlk), address(voter));
        voter.initializePeers(address(lpLocker), address(pd), feeCollector);

        // Post-launch wiring the gate's A-section checks (hook committed, registrar renounced).
        voter.setPoolHooks(address(0));
        vm.prank(lpRegistrar);
        lpLocker.renounceRegistrar();

        // 4. Migrator owned by the timelock, funded, root set.
        migrator = new BwlkMigration(
            timelock,
            BMX,
            address(bwlk),
            address(staked),
            address(bonus),
            address(fee),
            address(bnBwlk),
            address(voter),
            deadline
        );
        vm.prank(escrow);
        IERC20(address(bwlk)).transfer(address(migrator), EthereumConfig.MIGRATION_POOL);
        vm.prank(timelock);
        migrator.setMerkleRoot(keccak256("root"));

        // 5. BWLK staking grants (runbook step, executed here by the doubles' gov = this test).
        staked.setHandler(address(migrator), true);
        bonus.setHandler(address(migrator), true);
        fee.setHandler(address(migrator), true);
        bnBwlk.setMinter(address(migrator), true);
        staked.setHandler(address(bonus), true);
        bonus.setHandler(address(fee), true);
        staked.setDepositToken(address(bwlk), true);
        bonus.setDepositToken(address(staked), true);
        fee.setDepositToken(address(bonus), true);
        fee.setDepositToken(address(bnBwlk), true);
    }

    function _cfg() internal view returns (AssertBwlkDeploy.Config memory) {
        return AssertBwlkDeploy.Config({
            migrator: address(migrator),
            voter: address(voter),
            bwlk: address(bwlk),
            bmx: BMX,
            stakedBwlkTracker: address(staked),
            bonusBwlkTracker: address(bonus),
            feeBwlkTracker: address(fee),
            bnBwlk: address(bnBwlk),
            timelock: timelock,
            stakingGov: address(this),
            auction: address(0), // no live BWLK auction on the fork; run() warns when skipped
            burner: address(0),
            // Pre-launch stage: no CCA position exists to register (A-9), so the locker section
            // is skipped here; BwlkDeployAssertion.t.sol covers A-5..A-9 with doubles.
            lpLocker: address(0),
            totalMigratableBmx: EthereumConfig.MIGRATION_POOL,
            expectedTrackerCodehash: address(staked).codehash,
            expectedBnTokenCodehash: address(bnBwlk).codehash,
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
        AssertBwlkDeploy.Config memory cfg = _cfg();
        cfg.totalMigratableBmx = EthereumConfig.MIGRATION_POOL + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                AssertBwlkDeploy.D1_PoolUndersized.selector, EthereumConfig.MIGRATION_POOL, cfg.totalMigratableBmx
            )
        );
        gate.assertAll(cfg);
    }

    /// @notice Injected D-3 violation (migrator loses its handler role) reverts the gate on the fork.
    function testFork_AssertReverts_OnMissingHandler() public onlyFork {
        fee.setHandler(address(migrator), false);
        vm.expectRevert(abi.encodeWithSelector(AssertBwlkDeploy.D3_MigratorNotHandler.selector, address(fee)));
        gate.assertAll(_cfg());
    }
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BwsMigration} from "src/token/BwsMigration.sol";

/// @dev Live admin surface of the Morphex RewardTracker / MintableBaseToken (Governable).
interface IStakingAdmin {
    function gov() external view returns (address);
    function setHandler(
        address handler,
        bool active
    ) external;
}

interface IBnAdmin {
    function gov() external view returns (address);
    function setMinter(
        address minter,
        bool active
    ) external;
}

interface ITrackerView {
    function balanceOf(
        address account
    ) external view returns (uint256);
    function depositBalances(
        address account,
        address depositToken
    ) external view returns (uint256);
}

/// @dev Minimal voter stub (migration is blocked only while finalizing; here it never is).
contract NotFinalizingVoter {
    function finalizationInProgress() external pure returns (bool) {
        return false;
    }
}

/// @title BwsMigrationForkTest
/// @notice Base mainnet fork test for the migration flow against the deployed Morphex GMX-style staking
///         (the sbfBMX 3-tier trackers + bnBMX). BWS trackers are not deployed yet, so this exercises
///         the Migrator's `stakeForAccount` 3-tier + bnBMX point-credit logic against the actual tracker
///         bytecode, using BMX as the stand-in staked asset (the live trackers accept BMX as the tier-1
///         deposit token). The destination ends with a staked position (sbfBMX balance) and voter points.
///
/// @dev Run with: forge test --match-contract BwsMigrationForkTest --fork-url https://mainnet.base.org -vvv
contract BwsMigrationForkTest is Test {
    address constant BMX = 0x548f93779fBC992010C07467cBaf329DD5F059B7;
    address constant BN_BMX = 0x10AB197551BAB91f8B218dC9730AE0e43d893Db2;
    address constant STAKED_TRACKER = 0x3085F25Cbb5F34531229077BAAC20B9ef2AE85CB;
    address constant BONUS_TRACKER = 0x9A8f034Df900E58C55764fAAC867c5BA11A8F70f;
    address constant FEE_TRACKER = 0x38E5be3501687500E6338217276069d16178077E; // sbfBMX
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    BwsMigration public migrator;
    NotFinalizingVoter public voter;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public dest = makeAddr("dest");
    uint256 public deadline;

    bool internal forked;

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function setUp() public {
        // Run with --fork-url, or self-fork from BASE_RPC_URL; without either the suite skips
        // (CI runs with no RPC configured).
        if (BMX.code.length == 0) {
            string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) return;
            vm.createSelectFork(rpcUrl);
        }
        forked = true;

        voter = new NotFinalizingVoter();
        deadline = block.timestamp + 30 days;

        // bws == BMX here: the live trackers' tier-1 deposit token is BMX, so we stand BMX in for BWS.
        migrator = new BwsMigration(
            owner, BMX, BMX, STAKED_TRACKER, BONUS_TRACKER, FEE_TRACKER, BN_BMX, address(voter), deadline
        );

        // Grant the Migrator the deploy-time roles the staking governor would grant in production.
        _grantHandler(STAKED_TRACKER);
        _grantHandler(BONUS_TRACKER);
        _grantHandler(FEE_TRACKER);
        address bnGov = IBnAdmin(BN_BMX).gov();
        vm.prank(bnGov);
        IBnAdmin(BN_BMX).setMinter(address(migrator), true);

        // Fund the migration pool.
        deal(BMX, address(migrator), 2_000_000e18);
    }

    function _grantHandler(
        address tracker
    ) internal {
        address g = IStakingAdmin(tracker).gov();
        vm.prank(g);
        IStakingAdmin(tracker).setHandler(address(migrator), true);
    }

    function testFork_Migrate_RecipientGetsStakedPosition() public onlyFork {
        vm.prank(owner);
        migrator.setMerkleRoot(keccak256("dummy"));

        uint256 amount = 1_000e18;
        deal(BMX, alice, amount);
        vm.prank(alice);
        IERC20(BMX).approve(address(migrator), amount);

        uint256 destWeightBefore = ITrackerView(FEE_TRACKER).balanceOf(dest);
        uint256 deadBefore = IERC20(BMX).balanceOf(DEAD);

        vm.prank(alice);
        migrator.migrate(dest, 0, 0, new bytes32[](0));

        // BMX surrendered.
        assertEq(IERC20(BMX).balanceOf(alice), 0, "alice BMX surrendered");
        assertEq(IERC20(BMX).balanceOf(DEAD) - deadBefore, amount, "BMX burned to dead");

        // Recipient holds a real staked position in the live trackers, plus the 16% base credit
        // (every migrator earns 16% of the migrated BMX as voter points, no snapshot leaf required).
        uint256 baseCredit = amount * 1_600 / 10_000; // 160e18
        assertEq(ITrackerView(STAKED_TRACKER).depositBalances(dest, BMX), amount, "principal staked for dest");
        assertEq(ITrackerView(FEE_TRACKER).depositBalances(dest, BN_BMX), baseCredit, "16% base credit to dest");
        assertEq(
            ITrackerView(FEE_TRACKER).balanceOf(dest) - destWeightBefore,
            amount + baseCredit,
            "sbf weight = principal + base credit"
        );
        // Caller (alice) received nothing — position went to the destination.
        assertEq(ITrackerView(STAKED_TRACKER).depositBalances(alice, BMX), 0, "caller got no position");
    }

    function testFork_Migrate_WithPoints_CreditsRealBnBmx() public onlyFork {
        uint256 amount = 1_000e18;
        deal(BMX, alice, amount);
        vm.prank(alice);
        IERC20(BMX).approve(address(migrator), amount);

        // Snapshot: 1000 BMX, 0 prior points -> 16% credit = 160 points. Single-leaf root.
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(alice, amount, uint256(0)))));
        vm.prank(owner);
        migrator.setMerkleRoot(leaf);

        uint256 destWeightBefore = ITrackerView(FEE_TRACKER).balanceOf(dest);

        vm.prank(alice);
        migrator.migrate(dest, amount, 0, new bytes32[](0));

        uint256 expectedPoints = amount * 1_600 / 10_000; // 160e18
        assertEq(
            ITrackerView(FEE_TRACKER).depositBalances(dest, BN_BMX),
            expectedPoints,
            "voter points (bnBMX) credited to dest"
        );
        assertEq(
            ITrackerView(FEE_TRACKER).balanceOf(dest) - destWeightBefore,
            amount + expectedPoints,
            "weight = principal + credited points"
        );
        // The real bnBMX transferFrom skips allowance for handlers (the fee tracker is one), so only
        // _stakePoints' explicit reset keeps this at zero.
        assertEq(IERC20(BN_BMX).allowance(address(migrator), FEE_TRACKER), 0, "no standing bnBMX allowance after stake");
    }
}

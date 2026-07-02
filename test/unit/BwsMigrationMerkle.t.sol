// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BWS} from "src/token/BWS.sol";
import {BwsMigration} from "src/token/BwsMigration.sol";
import {ArbitrumConfig} from "script/bws/ArbitrumConfig.sol";
import {
    MockRewardTrackerFull,
    MockBnToken,
    MockMintableERC20,
    NotFinalizingVoter
} from "test/bws/MockMorphexStaking.sol";

/// @title BwsMigrationMerkleTest
/// @notice Cross-language leaf round-trip. The merkle root and proofs below were generated off-chain by
///         the `snapshot` pipeline (OpenZeppelin StandardMerkleTree, leaf encoding
///         ["address","uint256","uint256"]) and checked into
///         `snapshot/fixtures/solidity-fixture.txt`. The tests feed those exact proofs into
///         on-chain `BwsMigration.migrate`. If the contract's leaf encoding
///         (`keccak256(bytes.concat(keccak256(abi.encode(account, snapshotBmx, snapshotPoints))))`)
///         drifts from the pipeline's, `migrate` rejects the proof and these tests fail.
contract BwsMigrationMerkleTest is Test {
    // ---- Pipeline-generated fixture (snapshot/fixtures/solidity-fixture.txt) ----
    bytes32 internal constant MERKLE_ROOT = 0xf03e3fed1b9eeb74c54825c153a32e78623de91d20a4e2f9a52d7797d02b33fe;

    address internal constant ACCOUNT_1 = 0x0000000000000000000000000000000000000001;
    uint256 internal constant SNAPSHOT_BMX_1 = 1000000000000000000000;
    uint256 internal constant SNAPSHOT_POINTS_1 = 0;

    address internal constant ACCOUNT_3 = 0x0000000000000000000000000000000000000003;
    uint256 internal constant SNAPSHOT_BMX_3 = 25000000000000000000000;
    uint256 internal constant SNAPSHOT_POINTS_3 = 10000000000000000000000;

    BWS internal bws;
    MockMintableERC20 internal bmx;
    MockRewardTrackerFull internal staked;
    MockRewardTrackerFull internal bonus;
    MockRewardTrackerFull internal fee;
    MockBnToken internal bnBws;
    NotFinalizingVoter internal voter;
    BwsMigration internal migrator;

    address internal escrow = makeAddr("escrow");
    address internal dest = makeAddr("dest");

    function proof1() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = 0xb6d12dc267bad06fed56bfdb6fd10f990472b320c6029712b66b5489e4bb0b5a;
        p[1] = 0xdddb5c6396065dc94532a727006791e0cd5a6e94c4274704c79d5b8d283337ff;
    }

    function proof3() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = 0x56a25a3c7f492486d9826113b57983298b4725e4cf22e749449f53d6e8b84325;
        p[1] = 0x7a9a24ce602148267f17801a79c7c203ffaf48abcde9e081a2cd65ecc3591b9f;
    }

    function setUp() public {
        vm.prank(escrow);
        bws = new BWS(escrow, makeAddr("ccipAdmin"));

        bmx = new MockMintableERC20("BMX", "BMX");
        staked = new MockRewardTrackerFull("Staked BWS", "sBWS");
        bonus = new MockRewardTrackerFull("Bonus BWS", "snBWS");
        fee = new MockRewardTrackerFull("Staked + Bonus + Fee BWS", "sbfBWS");
        bnBws = new MockBnToken("Bonus BWS", "bnBWS");
        voter = new NotFinalizingVoter();

        migrator = new BwsMigration(
            address(this),
            address(bmx),
            address(bws),
            address(staked),
            address(bonus),
            address(fee),
            address(bnBws),
            address(voter),
            block.timestamp + 365 days
        );

        // Fund the pool and wire the staking exactly as the deploy runbook does.
        vm.prank(escrow);
        IERC20(address(bws)).transfer(address(migrator), ArbitrumConfig.MIGRATION_POOL);

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
        // Production wiring: bnBWS in private transfer mode with the fee tracker as handler, so
        // every migrate() here exercises the handler-bypass pull under private mode.
        bnBws.setInPrivateTransferMode(true);
        bnBws.setHandler(address(fee), true);

        // Owner sets the one-shot root to the pipeline-published value.
        migrator.setMerkleRoot(MERKLE_ROOT);
    }

    function _migrateAs(
        address account,
        uint256 broughtBmx,
        uint256 snapshotBmx,
        uint256 snapshotPoints,
        bytes32[] memory proof
    ) internal {
        bmx.mint(account, broughtBmx);
        vm.startPrank(account);
        IERC20(address(bmx)).approve(address(migrator), broughtBmx);
        migrator.migrate(dest, snapshotBmx, snapshotPoints, proof);
        vm.stopPrank();
    }

    /// @notice Entry 1 proof is accepted -> the pipeline leaf encoding matches the contract's.
    function test_PipelineProof_Accepted_Entry1() public {
        _migrateAs(ACCOUNT_1, SNAPSHOT_BMX_1, SNAPSHOT_BMX_1, SNAPSHOT_POINTS_1, proof1());

        assertTrue(migrator.migrated(ACCOUNT_1), "entry 1 migrated (proof accepted)");
        // Points = 16% of (snapshotBmx + snapshotPoints) at full ratio = 160e18.
        uint256 expected = (SNAPSHOT_BMX_1 + SNAPSHOT_POINTS_1) * 1_600 / 10_000;
        assertEq(fee.depositBalances(dest, address(bnBws)), expected, "entry 1 points credited");
        assertEq(staked.depositBalances(dest, address(bws)), SNAPSHOT_BMX_1, "entry 1 principal staked");
    }

    /// @notice A second independent entry under the same root also verifies.
    function test_PipelineProof_Accepted_Entry3() public {
        _migrateAs(ACCOUNT_3, SNAPSHOT_BMX_3, SNAPSHOT_BMX_3, SNAPSHOT_POINTS_3, proof3());

        assertTrue(migrator.migrated(ACCOUNT_3), "entry 3 migrated (proof accepted)");
        // points = snapshotPoints + 16%*(snapshotBmx+snapshotPoints) at full ratio.
        uint256 expected = SNAPSHOT_POINTS_3 + (SNAPSHOT_BMX_3 + SNAPSHOT_POINTS_3) * 1_600 / 10_000;
        assertEq(fee.depositBalances(dest, address(bnBws)), expected, "entry 3 points credited");
    }

    /// @notice A tampered snapshot value (proof no longer matches the leaf) is rejected.
    function test_RevertWhen_PipelineProof_TamperedValue() public {
        bmx.mint(ACCOUNT_1, SNAPSHOT_BMX_1);
        vm.startPrank(ACCOUNT_1);
        IERC20(address(bmx)).approve(address(migrator), SNAPSHOT_BMX_1);
        vm.expectRevert(BwsMigration.InvalidProof.selector);
        migrator.migrate(dest, SNAPSHOT_BMX_1 - 1, SNAPSHOT_POINTS_1, proof1());
        vm.stopPrank();
    }

    /// @notice A valid proof presented by the wrong caller is rejected (leaf binds to msg.sender).
    function test_RevertWhen_PipelineProof_WrongCaller() public {
        bmx.mint(ACCOUNT_3, SNAPSHOT_BMX_1);
        vm.startPrank(ACCOUNT_3);
        IERC20(address(bmx)).approve(address(migrator), SNAPSHOT_BMX_1);
        vm.expectRevert(BwsMigration.InvalidProof.selector);
        migrator.migrate(dest, SNAPSHOT_BMX_1, SNAPSHOT_POINTS_1, proof1());
        vm.stopPrank();
    }
}

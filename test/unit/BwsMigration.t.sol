// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BwsMigration} from "src/token/BwsMigration.sol";
import {BWS} from "src/token/BWS.sol";

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

/// @dev Legacy BMX: plain ERC20 with open mint for test setup.
contract MockBMX is ERC20 {
    constructor() ERC20("BMX", "BMX") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @dev bnBWS multiplier-point token: ERC20 + minter-gated mint/burn (mirrors MintableBaseToken),
///      including the handler transferFrom branch that never touches allowance.
contract MockBnPoints is ERC20 {
    mapping(address => bool) public isMinter;
    mapping(address => bool) public isHandler;

    constructor() ERC20("Bonus BWS", "bnBWS") {}

    function setMinter(
        address account,
        bool active
    ) external {
        isMinter[account] = active;
    }

    function setHandler(
        address account,
        bool active
    ) external {
        isHandler[account] = active;
    }

    /// @dev Mirrors BaseToken.transferFrom: a handler transfers WITHOUT consuming allowance, so an
    ///      exact approval survives the stake unless the approver resets it.
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        if (isHandler[msg.sender]) {
            _transfer(from, to, value);
            return true;
        }
        return super.transferFrom(from, to, value);
    }

    function mint(
        address account,
        uint256 amount
    ) external {
        require(isMinter[msg.sender], "not minter");
        _mint(account, amount);
    }

    function burn(
        address account,
        uint256 amount
    ) external {
        require(isMinter[msg.sender], "not minter");
        _burn(account, amount);
    }
}

/// @dev Mock of Morphex RewardTracker: handler-gated `stakeForAccount` that pulls the deposit token and
///      credits accounting + a receipt balance, plus a `transferFrom` that bypasses allowance for
///      handlers (so inter-tier pulls work without the account approving).
contract MockTracker {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    mapping(address => bool) public isHandler;
    mapping(address => bool) public isDepositToken;
    mapping(address => mapping(address => uint256)) public depositBalances;
    mapping(address => uint256) public stakedAmounts;
    mapping(address => uint256) public totalDepositSupply;

    constructor(
        string memory _name,
        string memory _symbol
    ) {
        name = _name;
        symbol = _symbol;
    }

    function setHandler(
        address handler,
        bool active
    ) external {
        isHandler[handler] = active;
    }

    function setDepositToken(
        address token,
        bool active
    ) external {
        isDepositToken[token] = active;
    }

    function balanceOf(
        address account
    ) external view returns (uint256) {
        return balances[account];
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (!isHandler[msg.sender]) {
            uint256 a = allowances[from][msg.sender];
            require(a >= amount, "allowance");
            allowances[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function stakeForAccount(
        address fundingAccount,
        address account,
        address depositToken,
        uint256 amount
    ) external {
        require(isHandler[msg.sender], "tracker: forbidden");
        require(isDepositToken[depositToken], "tracker: invalid deposit token");
        require(amount > 0, "RewardTracker: invalid _amount");
        require(IERC20(depositToken).transferFrom(fundingAccount, address(this), amount), "pull failed");
        stakedAmounts[account] += amount;
        depositBalances[account][depositToken] += amount;
        totalDepositSupply[depositToken] += amount;
        _mint(account, amount);
    }

    function _mint(
        address account,
        uint256 amount
    ) private {
        totalSupply += amount;
        balances[account] += amount;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        require(balances[from] >= amount, "balance");
        balances[from] -= amount;
        balances[to] += amount;
    }
}

/// @dev Minimal GovernanceVoter stand-in exposing only `finalizationInProgress`.
contract MockVoterFin {
    bool public finalizing;

    function setFinalizing(
        bool v
    ) external {
        finalizing = v;
    }

    function finalizationInProgress() external view returns (bool) {
        return finalizing;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

contract BwsMigrationTest is Test {
    BwsMigration public migrator;
    BWS public bws;
    MockBMX public bmx;
    MockBnPoints public bnBws;
    MockTracker public stakedTracker;
    MockTracker public bonusTracker;
    MockTracker public feeTracker;
    MockVoterFin public voter;

    address public owner = address(this);
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public dest = makeAddr("dest");
    address public treasury = makeAddr("treasury");

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant POOL = 2_711_068e18;
    uint256 internal deadline;

    event Migrated(address indexed account, address indexed destination, uint256 bwsAmount, uint256 pointsCredited);
    event PointsCredited(address indexed destination, uint256 amount);
    event Swept(address indexed to, uint256 amount);
    event MerkleRootSet(bytes32 oldRoot, bytes32 newRoot);

    function setUp() public {
        bmx = new MockBMX();
        bws = new BWS(address(this), address(this)); // mints MAX_SUPPLY to this test
        bnBws = new MockBnPoints();
        stakedTracker = new MockTracker("Staked BWS", "sBWS");
        bonusTracker = new MockTracker("Bonus BWS", "bonusBWS");
        feeTracker = new MockTracker("Fee BWS", "sbfBWS");
        voter = new MockVoterFin();

        deadline = block.timestamp + 30 days;
        migrator = new BwsMigration(
            owner,
            address(bmx),
            address(bws),
            address(stakedTracker),
            address(bonusTracker),
            address(feeTracker),
            address(bnBws),
            address(voter),
            deadline
        );

        // Deploy-time wiring (granted by the staking governor in production).
        stakedTracker.setDepositToken(address(bws), true);
        bonusTracker.setDepositToken(address(stakedTracker), true);
        feeTracker.setDepositToken(address(bonusTracker), true);
        feeTracker.setDepositToken(address(bnBws), true);

        stakedTracker.setHandler(address(migrator), true);
        bonusTracker.setHandler(address(migrator), true);
        feeTracker.setHandler(address(migrator), true);
        stakedTracker.setHandler(address(bonusTracker), true); // bonus pulls staked
        bonusTracker.setHandler(address(feeTracker), true); // fee pulls bonus

        bnBws.setMinter(address(migrator), true);
        // Production wiring: the fee tracker is a bnBWS handler, so its transferFrom pull in
        // _stakePoints never consumes the migrator's allowance.
        bnBws.setHandler(address(feeTracker), true);

        // Fund the migration pool.
        bws.transfer(address(migrator), POOL);
    }

    // ---- helpers ----

    function _giveBmx(
        address who,
        uint256 amount
    ) internal {
        bmx.mint(who, amount);
        vm.prank(who);
        bmx.approve(address(migrator), type(uint256).max);
    }

    function _leaf(
        address account,
        uint256 snapshotBmx,
        uint256 snapshotPoints
    ) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, snapshotBmx, snapshotPoints))));
    }

    function _setRoot(
        bytes32 root
    ) internal {
        migrator.setMerkleRoot(root);
    }

    function _expectedPoints(
        uint256 brought,
        uint256 snapBmx,
        uint256 snapPoints
    ) internal pure returns (uint256) {
        uint256 base = brought * 1_600 / 10_000;
        if (snapBmx == 0) return base;
        uint256 b = brought < snapBmx ? brought : snapBmx;
        return base + snapPoints * (10_000 + 1_600) * b / (10_000 * snapBmx);
    }

    function _emptyProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    // ============ migrate: base credit (every migrator earns 16% of migrated BMX) ============

    function test_Migrate_NonStaker_BaseCredit() public {
        // No snapshot leaf: 1:1 BWS + 16% of the migrated BMX as voter points (160e18).
        _setRoot(keccak256("dummy"));
        _giveBmx(alice, 1_000e18);

        vm.expectEmit(true, true, true, true);
        emit Migrated(alice, dest, 1_000e18, 160e18);
        vm.prank(alice);
        migrator.migrate(dest, 0, 0, _emptyProof());

        assertEq(bmx.balanceOf(alice), 0, "bmx surrendered");
        assertEq(bmx.balanceOf(DEAD), 1_000e18, "bmx to dead");
        assertEq(stakedTracker.depositBalances(dest, address(bws)), 1_000e18, "staked principal");
        assertEq(feeTracker.depositBalances(dest, address(bnBws)), 160e18, "16% base credit");
        assertEq(feeTracker.balanceOf(dest), 1_160e18, "sbf weight = principal + base credit");
        assertTrue(migrator.migrated(alice), "marked migrated");
    }

    function test_Migrate_BurnsEntireBalance() public {
        _setRoot(keccak256("dummy"));
        _giveBmx(alice, 1_234e18);
        vm.prank(alice);
        migrator.migrate(dest, 0, 0, _emptyProof());
        assertEq(bmx.balanceOf(DEAD), 1_234e18);
        assertEq(stakedTracker.depositBalances(dest, address(bws)), 1_234e18);
    }

    // ============ migrate: points (worked examples, 16%) ============

    function test_Migrate_Points_Example1_Unstaked() public {
        // 100k BMX, 0 snapshot points -> 16k credit.
        _giveBmx(alice, 100_000e18);
        _setRoot(_leaf(alice, 100_000e18, 0));

        vm.prank(alice);
        migrator.migrate(dest, 100_000e18, 0, _emptyProof());

        assertEq(feeTracker.depositBalances(dest, address(bnBws)), 16_000e18, "16k points");
        assertEq(stakedTracker.depositBalances(dest, address(bws)), 100_000e18, "principal");
        assertEq(feeTracker.balanceOf(dest), 116_000e18, "weight 116k");
    }

    function test_Migrate_Points_Example2_Staked_FullBring() public {
        // 50k BMX + 50k points, bring 50k -> 66k points.
        _giveBmx(alice, 50_000e18);
        _setRoot(_leaf(alice, 50_000e18, 50_000e18));

        vm.prank(alice);
        migrator.migrate(dest, 50_000e18, 50_000e18, _emptyProof());

        assertEq(feeTracker.depositBalances(dest, address(bnBws)), 66_000e18, "66k points");
        assertEq(feeTracker.balanceOf(dest), 116_000e18, "weight 116k");
    }

    function test_Migrate_Points_Example3_PartialBring() public {
        // 50k/50k snapshot, bring only 25k -> 33k points, 25k principal.
        _giveBmx(alice, 25_000e18);
        _setRoot(_leaf(alice, 50_000e18, 50_000e18));

        vm.prank(alice);
        migrator.migrate(dest, 50_000e18, 50_000e18, _emptyProof());

        assertEq(feeTracker.depositBalances(dest, address(bnBws)), 33_000e18, "33k points");
        assertEq(stakedTracker.depositBalances(dest, address(bws)), 25_000e18, "25k principal");
        assertEq(feeTracker.balanceOf(dest), 58_000e18, "weight 58k");
    }

    function test_Migrate_Points_BroughtExceedsSnapshot_BaseUncappedCarryCapped() public {
        // snapshot 50k/50k, hold 80k: the 16% base is on the full 80k (12.8k); the carry is capped at
        // the staked 50k (58k) -> 70.8k points, 80k principal 1:1.
        _giveBmx(alice, 80_000e18);
        _setRoot(_leaf(alice, 50_000e18, 50_000e18));

        vm.prank(alice);
        migrator.migrate(dest, 50_000e18, 50_000e18, _emptyProof());

        assertEq(feeTracker.depositBalances(dest, address(bnBws)), 70_800e18, "base 16% of 80k + capped carry");
        assertEq(stakedTracker.depositBalances(dest, address(bws)), 80_000e18, "full principal 1:1");
        assertEq(feeTracker.balanceOf(dest), 150_800e18, "weight = principal + points");
    }

    function test_Migrate_LeafZeroSnapshotBmx_BaseCreditOnly() public {
        // A degenerate leaf with 0 BMX basis can't carry points (no ratio), but the migrator still
        // earns the 16% base on the migrated BMX (160e18).
        _giveBmx(alice, 1_000e18);
        _setRoot(_leaf(alice, 0, 500e18));

        vm.prank(alice);
        migrator.migrate(dest, 0, 500e18, _emptyProof());

        assertEq(feeTracker.depositBalances(dest, address(bnBws)), 160e18, "base credit only");
        assertEq(stakedTracker.depositBalances(dest, address(bws)), 1_000e18, "principal");
    }

    function test_Migrate_NotInSnapshot_GetsBaseCredit() public {
        // Root is bob's leaf; alice has no leaf -> 1:1 + 16% base credit on her 500e18 (80e18).
        _setRoot(_leaf(bob, 100e18, 0));
        _giveBmx(alice, 500e18);

        vm.prank(alice);
        migrator.migrate(dest, 0, 0, _emptyProof());

        assertEq(stakedTracker.depositBalances(dest, address(bws)), 500e18);
        assertEq(feeTracker.depositBalances(dest, address(bnBws)), 80e18, "16% base credit");
    }

    function test_Migrate_TwoLeafTree_RealProof() public {
        _giveBmx(alice, 10_000e18);
        bytes32 leafA = _leaf(alice, 10_000e18, 0);
        bytes32 leafB = _leaf(bob, 7_000e18, 0);
        bytes32 root = leafA < leafB ? keccak256(abi.encode(leafA, leafB)) : keccak256(abi.encode(leafB, leafA));
        _setRoot(root);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;

        vm.prank(alice);
        migrator.migrate(dest, 10_000e18, 0, proof);

        assertEq(feeTracker.depositBalances(dest, address(bnBws)), 1_600e18, "16% of 10k");
    }

    // ============ destination routing ============

    function test_Migrate_RoutesToDestination_NotSender() public {
        _setRoot(keccak256("dummy"));
        _giveBmx(alice, 1_000e18);
        vm.prank(alice);
        migrator.migrate(bob, 0, 0, _emptyProof());

        assertEq(stakedTracker.depositBalances(bob, address(bws)), 1_000e18, "bob got position");
        assertEq(stakedTracker.depositBalances(alice, address(bws)), 0, "alice got nothing");
        assertEq(bmx.balanceOf(alice), 0, "alice paid the bmx");
    }

    // ============ migrate reverts ============

    function test_RevertWhen_Migrate_AlreadyMigrated() public {
        _setRoot(keccak256("dummy"));
        _giveBmx(alice, 1_000e18);
        vm.prank(alice);
        migrator.migrate(dest, 0, 0, _emptyProof());

        _giveBmx(alice, 500e18);
        vm.expectRevert(BwsMigration.AlreadyMigrated.selector);
        vm.prank(alice);
        migrator.migrate(dest, 0, 0, _emptyProof());
    }

    function test_RevertWhen_Migrate_NothingToMigrate() public {
        _setRoot(keccak256("dummy"));
        vm.expectRevert(BwsMigration.NothingToMigrate.selector);
        vm.prank(alice);
        migrator.migrate(dest, 0, 0, _emptyProof());
    }

    function test_RevertWhen_Migrate_RootNotSet() public {
        _giveBmx(alice, 1_000e18);
        vm.expectRevert(BwsMigration.RootNotSet.selector);
        vm.prank(alice);
        migrator.migrate(dest, 0, 0, _emptyProof());
    }

    function test_RevertWhen_Migrate_ZeroDestination() public {
        _giveBmx(alice, 1_000e18);
        vm.expectRevert(BwsMigration.ZeroAddress.selector);
        vm.prank(alice);
        migrator.migrate(address(0), 0, 0, _emptyProof());
    }

    function test_RevertWhen_Migrate_AfterDeadline() public {
        _setRoot(keccak256("dummy"));
        _giveBmx(alice, 1_000e18);
        vm.warp(deadline + 1);
        vm.expectRevert(BwsMigration.ClaimWindowClosed.selector);
        vm.prank(alice);
        migrator.migrate(dest, 0, 0, _emptyProof());
    }

    function test_RevertWhen_Migrate_DuringFinalization() public {
        _setRoot(keccak256("dummy"));
        _giveBmx(alice, 1_000e18);
        voter.setFinalizing(true);
        vm.expectRevert(BwsMigration.FinalizationInProgress.selector);
        vm.prank(alice);
        migrator.migrate(dest, 0, 0, _emptyProof());
    }

    function test_RevertWhen_Migrate_InvalidProof() public {
        _giveBmx(alice, 100_000e18);
        _setRoot(_leaf(alice, 100_000e18, 0));
        // Wrong snapshotPoints -> leaf mismatch -> InvalidProof.
        vm.expectRevert(BwsMigration.InvalidProof.selector);
        vm.prank(alice);
        migrator.migrate(dest, 100_000e18, 999e18, _emptyProof());
    }

    // ============ setMerkleRoot ============

    function test_SetMerkleRoot() public {
        bytes32 r = keccak256("root");
        vm.expectEmit(true, true, true, true);
        emit MerkleRootSet(bytes32(0), r);
        migrator.setMerkleRoot(r);
        assertEq(migrator.merkleRoot(), r);
    }

    function test_RevertWhen_SetMerkleRoot_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        migrator.setMerkleRoot(keccak256("x"));
    }

    function test_RevertWhen_SetMerkleRoot_AlreadySet() public {
        migrator.setMerkleRoot(keccak256("root"));
        vm.expectRevert(BwsMigration.RootAlreadySet.selector);
        migrator.setMerkleRoot(keccak256("root2"));
    }

    // ============ creditPoints (post-migration correction) ============

    function test_CreditPoints_AfterMigration() public {
        _setRoot(keccak256("dummy"));
        _giveBmx(alice, 1_000e18);
        vm.prank(alice);
        migrator.migrate(dest, 0, 0, _emptyProof()); // 160e18 base credit (16% of 1_000e18)

        vm.expectEmit(true, true, true, true);
        emit PointsCredited(dest, 140e18);
        migrator.creditPoints(dest, 140e18);

        assertEq(feeTracker.depositBalances(dest, address(bnBws)), 300e18, "base 160 + post-hoc 140");
    }

    function test_RevertWhen_CreditPoints_DuringFinalization() public {
        voter.setFinalizing(true);
        vm.expectRevert(BwsMigration.FinalizationInProgress.selector);
        migrator.creditPoints(dest, 1e18);
    }

    function test_RevertWhen_CreditPoints_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        migrator.creditPoints(dest, 1e18);
    }

    function test_RevertWhen_CreditPoints_ZeroDestination() public {
        vm.expectRevert(BwsMigration.ZeroAddress.selector);
        migrator.creditPoints(address(0), 1e18);
    }

    function test_RevertWhen_CreditPoints_ZeroAmount() public {
        // creditPoints has no zero guard by design: the real tracker rejects zero-amount stakes.
        vm.expectRevert(bytes("RewardTracker: invalid _amount"));
        migrator.creditPoints(dest, 0);
    }

    // ============ sweepUnclaimed ============

    function test_SweepUnclaimed_AfterDeadline() public {
        // burn down some pool first
        _setRoot(keccak256("dummy"));
        _giveBmx(alice, 1_000e18);
        vm.prank(alice);
        migrator.migrate(dest, 0, 0, _emptyProof());

        uint256 remaining = bws.balanceOf(address(migrator));
        vm.warp(deadline + 1);

        vm.expectEmit(true, true, true, true);
        emit Swept(treasury, remaining);
        migrator.sweepUnclaimed(treasury);

        assertEq(bws.balanceOf(treasury), remaining, "swept to treasury");
        assertEq(bws.balanceOf(address(migrator)), 0, "pool drained");
    }

    function test_RevertWhen_SweepUnclaimed_BeforeDeadline() public {
        vm.expectRevert(BwsMigration.ClaimWindowOpen.selector);
        migrator.sweepUnclaimed(treasury);
    }

    function test_RevertWhen_SweepUnclaimed_NotOwner() public {
        vm.warp(deadline + 1);
        vm.expectRevert();
        vm.prank(alice);
        migrator.sweepUnclaimed(treasury);
    }

    function test_RevertWhen_SweepUnclaimed_ZeroTo() public {
        vm.warp(deadline + 1);
        vm.expectRevert(BwsMigration.ZeroAddress.selector);
        migrator.sweepUnclaimed(address(0));
    }

    // ============ constructor reverts ============

    function test_RevertWhen_Constructor_ZeroAddress() public {
        vm.expectRevert(BwsMigration.ZeroAddress.selector);
        new BwsMigration(
            owner,
            address(0),
            address(bws),
            address(stakedTracker),
            address(bonusTracker),
            address(feeTracker),
            address(bnBws),
            address(voter),
            deadline
        );
    }

    function test_RevertWhen_Constructor_DeadlineInPast() public {
        vm.expectRevert(BwsMigration.DeadlineInPast.selector);
        new BwsMigration(
            owner,
            address(bmx),
            address(bws),
            address(stakedTracker),
            address(bonusTracker),
            address(feeTracker),
            address(bnBws),
            address(voter),
            block.timestamp
        );
    }

    // ============ no standing approvals (exact-approve per stake) ============

    function test_NoStandingApproval_ExactApprovePerStake() public {
        assertEq(bws.allowance(address(migrator), address(stakedTracker)), 0, "no standing BWS approval");
        assertEq(bnBws.allowance(address(migrator), address(feeTracker)), 0, "no standing bnBWS approval");

        _setRoot(_leaf(alice, 1_000e18, 0));
        _giveBmx(alice, 1_000e18);
        vm.prank(alice);
        migrator.migrate(dest, 1_000e18, 0, _emptyProof());

        // BWS: the tracker's transferFrom consumes the exact approval. bnBWS: the fee tracker is a
        // HANDLER on bnBWS (wired in setUp, as in production), so its pull never touches allowance -
        // zero here proves _stakePoints' explicit reset, not consumption.
        assertEq(bws.allowance(address(migrator), address(stakedTracker)), 0, "BWS allowance fully consumed");
        assertEq(bnBws.allowance(address(migrator), address(feeTracker)), 0, "bnBWS allowance reset after stake");
    }

    // ============ fuzz: points formula ============

    function testFuzz_PointsFormula(
        uint96 snapBmx,
        uint96 snapPoints,
        uint96 hold
    ) public {
        snapBmx = uint96(bound(snapBmx, 1e18, 2_000_000e18));
        snapPoints = uint96(bound(snapPoints, 0, 2_000_000e18));
        hold = uint96(bound(hold, 1e18, 2_000_000e18));

        _giveBmx(alice, hold);
        _setRoot(_leaf(alice, snapBmx, snapPoints));

        vm.prank(alice);
        migrator.migrate(dest, snapBmx, snapPoints, _emptyProof());

        uint256 expected = _expectedPoints(hold, snapBmx, snapPoints);
        assertEq(feeTracker.depositBalances(dest, address(bnBws)), expected, "points formula");
        assertEq(stakedTracker.depositBalances(dest, address(bws)), hold, "principal 1:1");
    }
}

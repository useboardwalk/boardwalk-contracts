// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {FeeRecipientCollector} from "src/core/FeeRecipientCollector.sol";

/// @dev Mock token with a settable `feeDistributor()` getter, satisfying the
///      `IBoardwalkToken(token).feeDistributor() == msg.sender` gate inside
///      `FeeRecipientCollector.notifyFees`.
contract MockBoardwalkToken is ERC20 {
    address public feeDistributor;

    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {
        feeDistributor = msg.sender;
    }

    function setFeeDistributor(
        address fd
    ) external {
        feeDistributor = fd;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @dev Token that supports reentry into `notifyFees` during its own `transfer`. Used to
///      exercise the LOW-1 LIFO-starvation case: the tracked entry re-adds itself during each
///      claim, so a swap-and-pop loop reading `length - 1` keeps popping the SAME entry.
contract ReentrantToken {
    address public feeDistributor;
    address public collector;
    string public name = "Reentrant";
    string public symbol = "RNT";
    uint8 public decimals = 18;

    bool public reentryEnabled;
    uint256 public phantomBalance = 100;

    constructor(
        address _collector
    ) {
        feeDistributor = address(this); // self-pointing to satisfy the notifyFees gate.
        collector = _collector;
    }

    function setReentryEnabled(
        bool _v
    ) external {
        reentryEnabled = _v;
    }

    /// @dev Constant non-zero balance so `_safeClaimTo` always invokes `transfer`, which is the
    ///      reentry hook. Returns `true` so SafeERC20 doesn't revert.
    function balanceOf(
        address
    ) external view returns (uint256) {
        return phantomBalance;
    }

    function transfer(address, uint256) external returns (bool) {
        if (reentryEnabled) {
            // Re-register self into the collector's tracked set during `_safeClaimTo`.
            FeeRecipientCollector(collector).notifyFees(address(this), 0);
        }
        return true;
    }
}

/// @dev Token whose `transfer` always reverts. Self-points so the `notifyFees` gate accepts.
contract RevertingTransferToken {
    address public feeDistributor;
    string public name = "Reverting";
    string public symbol = "RVT";
    uint8 public decimals = 18;

    constructor() {
        feeDistributor = address(this); // self-pointing to satisfy the notifyFees gate.
    }

    function balanceOf(
        address
    ) external pure returns (uint256) {
        return 100;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("RevertingTransferToken: forced revert");
    }
}

/// @dev Mock FeeDistributor exposing the `integrator()` / `ancillary()` views and the
///      timelocked rotation entry-points consumed by the collector's batch helpers. Records
///      the last invoked branch so tests can assert which path fired.
contract MockFeeDistributorRouter {
    address public integrator;
    address public ancillary;

    address public lastSignalAddr;
    address public lastExecuteAddr;
    bytes32 public lastSelector;

    bool public revertOnSignal;

    function mockSetIntegrator(
        address _i
    ) external {
        integrator = _i;
    }

    function mockSetAncillary(
        address _a
    ) external {
        ancillary = _a;
    }

    function setRevertOnSignal(
        bool _v
    ) external {
        revertOnSignal = _v;
    }

    function signalChangeIntegratorAddress(
        address newAddress
    ) external {
        if (revertOnSignal) revert("MockFD: forced revert");
        lastSignalAddr = newAddress;
        lastSelector = keccak256("integratorSignal");
    }

    function signalChangeAncillaryAddress(
        address newAddress
    ) external {
        if (revertOnSignal) revert("MockFD: forced revert");
        lastSignalAddr = newAddress;
        lastSelector = keccak256("ancillarySignal");
    }

    function executeChangeIntegratorAddress(
        address newAddress
    ) external {
        lastExecuteAddr = newAddress;
        lastSelector = keccak256("integratorExecute");
        integrator = newAddress;
    }

    function executeChangeAncillaryAddress(
        address newAddress
    ) external {
        lastExecuteAddr = newAddress;
        lastSelector = keccak256("ancillaryExecute");
        ancillary = newAddress;
    }

    function cancelChangeIntegratorAddress() external {
        lastSelector = keccak256("integratorCancel");
    }

    function cancelChangeAncillaryAddress() external {
        lastSelector = keccak256("ancillaryCancel");
    }
}

/// @dev Mock LaunchFactory exposing the same role views and rotation entry-points as
///      `MockFeeDistributorRouter` but used for the factory-side helpers.
contract MockLaunchFactoryRouter {
    address public integrator;
    address public ancillary;

    address public lastSignalAddr;
    bytes32 public lastSelector;

    function setIntegrator(
        address _i
    ) external {
        integrator = _i;
    }

    function setAncillary(
        address _a
    ) external {
        ancillary = _a;
    }

    function signalChangeIntegratorAddress(
        address newAddress
    ) external {
        lastSignalAddr = newAddress;
        lastSelector = keccak256("integratorSignal");
    }

    function signalChangeAncillaryAddress(
        address newAddress
    ) external {
        lastSignalAddr = newAddress;
        lastSelector = keccak256("ancillarySignal");
    }

    function cancelChangeIntegratorAddress() external {
        lastSelector = keccak256("integratorCancel");
    }

    function cancelChangeAncillaryAddress() external {
        lastSelector = keccak256("ancillaryCancel");
    }
}

contract FeeRecipientCollectorTest is Test {
    FeeRecipientCollector internal collector;
    MockBoardwalkToken internal tokenA;
    MockBoardwalkToken internal tokenB;
    MockBoardwalkToken internal tokenC;
    address internal feeDistributorA;
    address internal feeDistributorB;
    address internal owner;
    address internal alice;
    address internal bob;

    /// @dev Mirror of the cap chosen in `FeeDistributor` (NOTIFY_GAS_LIMIT = 150_000) minus a
    ///      safety headroom. Cold-path notifyFees must measure strictly under this so a future
    ///      change (extra SSTORE in `notifyFees`, OZ `EnumerableSet` evolution, compiler
    ///      regression) surfaces explicitly. Empirical cold-path cost under
    ///      `forge test --isolate` is ~103K (two cold SSTOREs in `EnumerableSet.add` + cold
    ///      SLOAD on the token's `feeDistributor()` + entry/dispatch/event); 125K leaves a
    ///      ~22K guard band before the cap. Re-calibrate `NOTIFY_GAS_LIMIT` if cold grows past
    ///      125K. **The pin tests require `--isolate`** — without it, cold-storage costs are
    ///      undercounted because helper calls warm slots earlier in the same test frame.
    uint256 internal constant NOTIFY_GAS_HEADROOM_CEILING = 125_000;

    event TokenRegistered(address indexed token, address indexed feeDistributor);
    event FeesClaimed(address indexed token, uint256 amount, address indexed to);
    event ClaimFailed(address indexed token);
    event TokenRemoved(address indexed token);

    function setUp() public {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        feeDistributorA = makeAddr("feeDistributorA");
        feeDistributorB = makeAddr("feeDistributorB");

        collector = new FeeRecipientCollector(owner);

        // tokenA / tokenB are normal mocks whose `feeDistributor()` returns a labeled address
        // so we can prove the gate validates correctly.
        tokenA = new MockBoardwalkToken("TokenA", "TKA");
        tokenA.setFeeDistributor(feeDistributorA);
        tokenB = new MockBoardwalkToken("TokenB", "TKB");
        tokenB.setFeeDistributor(feeDistributorB);
        tokenC = new MockBoardwalkToken("TokenC", "TKC");
        tokenC.setFeeDistributor(feeDistributorA);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  notifyFees — gating + idempotence
    // ──────────────────────────────────────────────────────────────────────────

    function test_NotifyFees_LegitimateCaller_RegistersToken() public {
        vm.expectEmit(true, true, false, false, address(collector));
        emit TokenRegistered(address(tokenA), feeDistributorA);

        vm.prank(feeDistributorA);
        collector.notifyFees(address(tokenA), 1e18);

        assertTrue(collector.isTracked(address(tokenA)), "tokenA should be tracked");
        assertEq(collector.trackedTokenCount(), 1, "set length should be 1");
        assertEq(collector.trackedTokenAt(0), address(tokenA), "set[0] should be tokenA");
    }

    function test_RevertWhen_NotifyFees_SpoofedSender() public {
        // Anyone whose address doesn't match tokenA.feeDistributor() should be rejected.
        vm.expectRevert(FeeRecipientCollector.UnknownSender.selector);
        vm.prank(alice);
        collector.notifyFees(address(tokenA), 1e18);
    }

    function test_NotifyFees_Idempotent_DoesNotDoubleAdd() public {
        vm.startPrank(feeDistributorA);
        collector.notifyFees(address(tokenA), 1e18);
        collector.notifyFees(address(tokenA), 2e18);
        vm.stopPrank();

        assertEq(collector.trackedTokenCount(), 1, "duplicate notify should not double-add");
    }

    function test_NotifyFees_DistinctTokens_AddsBoth() public {
        vm.prank(feeDistributorA);
        collector.notifyFees(address(tokenA), 1e18);
        vm.prank(feeDistributorB);
        collector.notifyFees(address(tokenB), 2e18);

        assertEq(collector.trackedTokenCount(), 2, "should track both tokens");
        assertTrue(collector.isTracked(address(tokenA)), "tokenA tracked");
        assertTrue(collector.isTracked(address(tokenB)), "tokenB tracked");
    }

    /// @notice The notifyFees gate is *cross-checked* against the token's `feeDistributor()`,
    ///         not against a protocol-owned authorization list. A malicious self-pointing fake
    ///         token can therefore register itself — but only at gas cost, with no fund risk.
    function test_NotifyFees_SelfPointingFakeToken_RegistersButNoFunds() public {
        ReentrantToken fake = new ReentrantToken(address(collector));
        // fake.feeDistributor() == address(fake), so calling collector.notifyFees from the fake
        // contract's own context (msg.sender = address(fake)) passes the gate.
        vm.prank(address(fake));
        collector.notifyFees(address(fake), 0);
        assertTrue(collector.isTracked(address(fake)), "fake token registered (gas-grief surface)");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  batchClaim — happy path, empty, LIFO, reverting token
    // ──────────────────────────────────────────────────────────────────────────

    function test_BatchClaim_DrainsAllTrackedTokens() public {
        _registerAndFund(tokenA, feeDistributorA, 100e18);
        _registerAndFund(tokenB, feeDistributorB, 200e18);

        vm.prank(owner);
        collector.batchClaim(0); // limit==0 means all

        assertEq(tokenA.balanceOf(owner), 100e18, "owner should receive tokenA balance");
        assertEq(tokenB.balanceOf(owner), 200e18, "owner should receive tokenB balance");
        assertEq(collector.trackedTokenCount(), 0, "set should be empty after drain");
    }

    function test_BatchClaim_LimitParameterRespected() public {
        _registerAndFund(tokenA, feeDistributorA, 100e18);
        _registerAndFund(tokenB, feeDistributorB, 200e18);
        _registerAndFund(tokenC, feeDistributorA, 300e18);
        // EnumerableSet order at this point: [tokenA, tokenB, tokenC]. LIFO claims pop the end.

        vm.prank(owner);
        collector.batchClaim(1); // claim only the last one (tokenC)

        assertEq(tokenC.balanceOf(owner), 300e18, "tokenC should be claimed");
        assertEq(tokenA.balanceOf(owner), 0, "tokenA should still be in collector");
        assertEq(tokenB.balanceOf(owner), 0, "tokenB should still be in collector");
        assertEq(collector.trackedTokenCount(), 2, "two tokens should remain");
    }

    function test_RevertWhen_BatchClaim_EmptySet() public {
        vm.prank(owner);
        vm.expectRevert(FeeRecipientCollector.NothingToClaim.selector);
        collector.batchClaim(0);
    }

    function test_RevertWhen_BatchClaim_NotOwner() public {
        _registerAndFund(tokenA, feeDistributorA, 100e18);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        collector.batchClaim(0);
    }

    /// @notice A reverting tracked token must NOT brick `batchClaim`. The try/catch around the
    ///         self-call drops the token from the set and emits `ClaimFailed`.
    function test_BatchClaim_RevertingToken_EmitsClaimFailedAndDrops() public {
        _registerAndFund(tokenA, feeDistributorA, 100e18);
        RevertingTransferToken rev = new RevertingTransferToken();
        vm.prank(address(rev));
        collector.notifyFees(address(rev), 0); // self-points → passes gate.

        // Set order: [tokenA, rev]. LIFO: rev pops first.
        vm.expectEmit(true, false, false, false, address(collector));
        emit ClaimFailed(address(rev));

        vm.prank(owner);
        collector.batchClaim(0);

        assertEq(tokenA.balanceOf(owner), 100e18, "tokenA should still be drained");
        assertFalse(collector.isTracked(address(rev)), "reverting token should be dropped from set");
    }

    /// @notice `_safeClaimTo` is `external` so that `batchClaim` can wrap it in `try/catch`,
    ///         but it must reject any caller other than the collector itself.
    function test_RevertWhen_SafeClaimTo_DirectExternalCall() public {
        vm.expectRevert(FeeRecipientCollector.UnknownSender.selector);
        vm.prank(alice);
        collector._safeClaimTo(address(tokenA), alice);
    }

    /// @notice LOW-1 regression: a malicious tracked token re-adds itself during its own
    ///         `transfer` call (via reentrant `notifyFees`). Without the snapshot-then-iterate
    ///         fix, this would starve earlier-indexed legitimate tokens in the same batch
    ///         because the loop always read `length - 1` and re-adds appended at the LIFO end.
    ///         The fix snapshots the high-water mark and decrements the index, so the loop
    ///         visits each ORIGINAL position regardless of mid-batch re-adds.
    function test_BatchClaim_ReentrantToken_DoesNotStarveLegitimateTokens() public {
        _registerAndFund(tokenA, feeDistributorA, 100e18); // legitimate, in set first.

        ReentrantToken fake = new ReentrantToken(address(collector));
        fake.setReentryEnabled(true);
        vm.prank(address(fake));
        collector.notifyFees(address(fake), 0); // set order: [tokenA, fake]; fake at snapshotIdx=1.

        // batchClaim(2) with the snapshot-iterate fix:
        //   iter 0: snapshotIdx = 1 → at(1) = fake → remove → set: [tokenA] (length 1).
        //           _safeClaimTo invokes fake.transfer; during transfer fake re-adds itself via
        //           notifyFees → set: [tokenA, fake] (length 2).
        //   iter 1: snapshotIdx = 0 → at(0) = tokenA → remove → swap-and-pop with last (fake) →
        //           set: [fake] (length 1). _safeClaimTo drains tokenA's 100e18 to owner.
        // tokenA WAS visited and drained despite the reentry; only the re-added `fake` lingers.
        vm.prank(owner);
        collector.batchClaim(2);

        assertEq(tokenA.balanceOf(owner), 100e18, "LOW-1 fix: tokenA drained despite reentry-readd");
        assertTrue(collector.isTracked(address(fake)), "fake re-added itself, still tracked");

        // Cleanup: owner can drop the re-added entry without claiming.
        vm.prank(owner);
        collector.removeTrackedToken(address(fake));
        assertFalse(collector.isTracked(address(fake)), "fake removed by owner");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  claimToken — rescue path
    // ──────────────────────────────────────────────────────────────────────────

    function test_ClaimToken_OwnerOnly() public {
        _registerAndFund(tokenA, feeDistributorA, 50e18);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        collector.claimToken(address(tokenA));
    }

    function test_ClaimToken_BypassesSet_ClaimsBalance() public {
        // Donation: tokens land at the collector without notifyFees ever being called.
        tokenA.mint(address(collector), 75e18);
        assertFalse(collector.isTracked(address(tokenA)), "donation should not be tracked");

        vm.expectEmit(true, true, true, false, address(collector));
        emit FeesClaimed(address(tokenA), 75e18, owner);

        vm.prank(owner);
        collector.claimToken(address(tokenA));

        assertEq(tokenA.balanceOf(owner), 75e18, "owner receives donated balance");
    }

    function test_ClaimToken_ZeroBalance_NoEvent() public {
        // No tokens at the collector — claimToken should silently no-op (no event, no transfer).
        vm.recordLogs();
        vm.prank(owner);
        collector.claimToken(address(tokenA));
        assertEq(vm.getRecordedLogs().length, 0, "no event when balance is zero");
    }

    function test_ClaimToken_RemovesFromSet() public {
        _registerAndFund(tokenA, feeDistributorA, 50e18);
        assertTrue(collector.isTracked(address(tokenA)), "tracked before");

        vm.prank(owner);
        collector.claimToken(address(tokenA));

        assertFalse(collector.isTracked(address(tokenA)), "removed from set after claim");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  removeTrackedToken
    // ──────────────────────────────────────────────────────────────────────────

    function test_RemoveTrackedToken_OwnerOnly() public {
        _registerAndFund(tokenA, feeDistributorA, 50e18);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        collector.removeTrackedToken(address(tokenA));
    }

    function test_RemoveTrackedToken_DropsWithoutClaim() public {
        _registerAndFund(tokenA, feeDistributorA, 50e18);

        vm.expectEmit(true, false, false, false, address(collector));
        emit TokenRemoved(address(tokenA));

        vm.prank(owner);
        collector.removeTrackedToken(address(tokenA));

        // Balance still on collector (not claimed); owner can rescue via `claimToken` later.
        assertEq(tokenA.balanceOf(address(collector)), 50e18, "balance untouched");
        assertFalse(collector.isTracked(address(tokenA)), "removed from set");
    }

    function test_RemoveTrackedToken_Idempotent() public {
        // Removing an unknown token is fine — EnumerableSet.remove returns false silently.
        vm.prank(owner);
        collector.removeTrackedToken(address(tokenA));
        // No revert.
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Batch typed rotation helpers (signal/execute/cancel on distributors)
    //
    //  The collector loops over the FD's typed signal/execute/cancel calls. Per-clone
    //  timelock lives on the FD itself; this is just UX batching.
    // ──────────────────────────────────────────────────────────────────────────

    function _twoFds() internal returns (MockFeeDistributorRouter fd1, MockFeeDistributorRouter fd2) {
        fd1 = new MockFeeDistributorRouter();
        fd2 = new MockFeeDistributorRouter();
    }

    function test_SignalChangeOnDistributors_AsIntegrator_RoutesToIntegrator() public {
        (MockFeeDistributorRouter fd1, MockFeeDistributorRouter fd2) = _twoFds();
        fd1.mockSetIntegrator(address(collector));
        fd2.mockSetIntegrator(address(collector));

        address[] memory distributors = new address[](2);
        distributors[0] = address(fd1);
        distributors[1] = address(fd2);
        address newAddr = makeAddr("newRole");

        vm.prank(owner);
        collector.signalChangeOnDistributors(distributors, newAddr);

        assertEq(fd1.lastSelector(), keccak256("integratorSignal"), "fd1 routed to integrator branch");
        assertEq(fd2.lastSelector(), keccak256("integratorSignal"), "fd2 routed to integrator branch");
        assertEq(fd1.lastSignalAddr(), newAddr, "fd1 newAddr threaded");
        assertEq(fd2.lastSignalAddr(), newAddr, "fd2 newAddr threaded");
    }

    function test_SignalChangeOnDistributors_AsAncillary_RoutesToAncillary() public {
        (MockFeeDistributorRouter fd1,) = _twoFds();
        fd1.mockSetAncillary(address(collector));

        address[] memory distributors = new address[](1);
        distributors[0] = address(fd1);

        vm.prank(owner);
        collector.signalChangeOnDistributors(distributors, makeAddr("newRole"));

        assertEq(fd1.lastSelector(), keccak256("ancillarySignal"), "fd1 routed to ancillary branch");
    }

    function test_RevertWhen_SignalChangeOnDistributors_NeitherRole() public {
        (MockFeeDistributorRouter fd1,) = _twoFds();
        fd1.mockSetIntegrator(makeAddr("someoneElse"));
        fd1.mockSetAncillary(makeAddr("someoneElseToo"));

        address[] memory distributors = new address[](1);
        distributors[0] = address(fd1);

        vm.expectRevert(FeeRecipientCollector.NotMyRole.selector);
        vm.prank(owner);
        collector.signalChangeOnDistributors(distributors, makeAddr("any"));
    }

    function test_RevertWhen_SignalChangeOnDistributors_NotOwner() public {
        (MockFeeDistributorRouter fd1,) = _twoFds();
        fd1.mockSetIntegrator(address(collector));

        address[] memory distributors = new address[](1);
        distributors[0] = address(fd1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        collector.signalChangeOnDistributors(distributors, makeAddr("any"));
    }

    /// @notice One FD reverting on signal aborts the whole batch — atomic by EVM semantics.
    function test_RevertWhen_SignalChangeOnDistributors_OneReverts() public {
        (MockFeeDistributorRouter fd1, MockFeeDistributorRouter fd2) = _twoFds();
        fd1.mockSetIntegrator(address(collector));
        fd2.mockSetIntegrator(address(collector));
        fd2.setRevertOnSignal(true);

        address[] memory distributors = new address[](2);
        distributors[0] = address(fd1);
        distributors[1] = address(fd2);

        vm.expectRevert();
        vm.prank(owner);
        collector.signalChangeOnDistributors(distributors, makeAddr("any"));

        // fd1's signal should also be rolled back on the outer revert (state unwind).
        assertEq(fd1.lastSelector(), bytes32(0), "fd1 signal reverted by atomic batch");
    }

    function test_ExecuteChangeOnDistributors_RotatesAll_PermissionlessCaller() public {
        (MockFeeDistributorRouter fd1, MockFeeDistributorRouter fd2) = _twoFds();
        fd1.mockSetIntegrator(address(collector));
        fd2.mockSetIntegrator(address(collector));

        address[] memory distributors = new address[](2);
        distributors[0] = address(fd1);
        distributors[1] = address(fd2);
        address newIntegrator = makeAddr("newIntegrator");

        // No prank — anyone can call executeChangeOnDistributors after the FDs have signaled.
        collector.executeChangeOnDistributors(distributors, newIntegrator);

        assertEq(fd1.integrator(), newIntegrator, "fd1 integrator rotated");
        assertEq(fd2.integrator(), newIntegrator, "fd2 integrator rotated");
    }

    function test_RevertWhen_ExecuteChangeOnDistributors_NeitherRole() public {
        (MockFeeDistributorRouter fd1,) = _twoFds();
        // fd1 has neither integrator nor ancillary set to collector.
        address[] memory distributors = new address[](1);
        distributors[0] = address(fd1);

        vm.expectRevert(FeeRecipientCollector.NotMyRole.selector);
        collector.executeChangeOnDistributors(distributors, makeAddr("any"));
    }

    function test_CancelChangeOnDistributors_AsIntegrator_RoutesToIntegrator() public {
        (MockFeeDistributorRouter fd1,) = _twoFds();
        fd1.mockSetIntegrator(address(collector));

        address[] memory distributors = new address[](1);
        distributors[0] = address(fd1);

        vm.prank(owner);
        collector.cancelChangeOnDistributors(distributors);

        assertEq(fd1.lastSelector(), keccak256("integratorCancel"), "fd1 routed to integrator cancel");
    }

    function test_CancelChangeOnDistributors_AsAncillary_RoutesToAncillary() public {
        (MockFeeDistributorRouter fd1,) = _twoFds();
        fd1.mockSetAncillary(address(collector));

        address[] memory distributors = new address[](1);
        distributors[0] = address(fd1);

        vm.prank(owner);
        collector.cancelChangeOnDistributors(distributors);

        assertEq(fd1.lastSelector(), keccak256("ancillaryCancel"), "fd1 routed to ancillary cancel");
    }

    function test_RevertWhen_CancelChangeOnDistributors_NeitherRole() public {
        (MockFeeDistributorRouter fd1,) = _twoFds();
        fd1.mockSetIntegrator(makeAddr("someoneElse"));
        fd1.mockSetAncillary(makeAddr("someoneElseToo"));

        address[] memory distributors = new address[](1);
        distributors[0] = address(fd1);

        vm.expectRevert(FeeRecipientCollector.NotMyRole.selector);
        vm.prank(owner);
        collector.cancelChangeOnDistributors(distributors);
    }

    function test_RevertWhen_CancelChangeOnDistributors_NotOwner() public {
        (MockFeeDistributorRouter fd1,) = _twoFds();
        fd1.mockSetIntegrator(address(collector));

        address[] memory distributors = new address[](1);
        distributors[0] = address(fd1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        collector.cancelChangeOnDistributors(distributors);
    }

    function test_SignalChangeOnFactory_AsIntegrator_RoutesToIntegrator() public {
        MockLaunchFactoryRouter f = new MockLaunchFactoryRouter();
        f.setIntegrator(address(collector));
        address newAddr = makeAddr("newRole");

        vm.prank(owner);
        collector.signalChangeOnFactory(address(f), newAddr);

        assertEq(f.lastSelector(), keccak256("integratorSignal"), "should route to integrator branch");
        assertEq(f.lastSignalAddr(), newAddr, "newAddr threaded through");
    }

    function test_SignalChangeOnFactory_AsAncillary_RoutesToAncillary() public {
        MockLaunchFactoryRouter f = new MockLaunchFactoryRouter();
        f.setAncillary(address(collector));
        address newAddr = makeAddr("newRole");

        vm.prank(owner);
        collector.signalChangeOnFactory(address(f), newAddr);

        assertEq(f.lastSelector(), keccak256("ancillarySignal"), "should route to ancillary branch");
    }

    function test_RevertWhen_SignalChangeOnFactory_NeitherRole() public {
        MockLaunchFactoryRouter f = new MockLaunchFactoryRouter();
        f.setIntegrator(makeAddr("someoneElse"));
        f.setAncillary(makeAddr("someoneElseToo"));

        vm.expectRevert(FeeRecipientCollector.NotMyRole.selector);
        vm.prank(owner);
        collector.signalChangeOnFactory(address(f), makeAddr("anyone"));
    }

    function test_RevertWhen_SignalChangeOnFactory_NotOwner() public {
        MockLaunchFactoryRouter f = new MockLaunchFactoryRouter();
        f.setIntegrator(address(collector));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        collector.signalChangeOnFactory(address(f), makeAddr("anyone"));
    }

    function test_RevertWhen_CancelChangeOnFactory_NeitherRole() public {
        MockLaunchFactoryRouter f = new MockLaunchFactoryRouter();
        f.setIntegrator(makeAddr("someoneElse"));
        f.setAncillary(makeAddr("someoneElseToo"));

        vm.expectRevert(FeeRecipientCollector.NotMyRole.selector);
        vm.prank(owner);
        collector.cancelChangeOnFactory(address(f));
    }

    function test_RevertWhen_CancelChangeOnFactory_NotOwner() public {
        MockLaunchFactoryRouter f = new MockLaunchFactoryRouter();
        f.setIntegrator(address(collector));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        collector.cancelChangeOnFactory(address(f));
    }

    function test_CancelChangeOnFactory_AsIntegrator() public {
        MockLaunchFactoryRouter f = new MockLaunchFactoryRouter();
        f.setIntegrator(address(collector));

        vm.prank(owner);
        collector.cancelChangeOnFactory(address(f));

        assertEq(f.lastSelector(), keccak256("integratorCancel"), "should route to integrator cancel");
    }

    function test_CancelChangeOnFactory_AsAncillary() public {
        MockLaunchFactoryRouter f = new MockLaunchFactoryRouter();
        f.setAncillary(address(collector));

        vm.prank(owner);
        collector.cancelChangeOnFactory(address(f));

        assertEq(f.lastSelector(), keccak256("ancillaryCancel"), "should route to ancillary cancel");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Ownable2Step transfer
    // ──────────────────────────────────────────────────────────────────────────

    function test_Ownable2Step_TransferOwnership_TwoStep() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: current owner initiates.
        vm.prank(owner);
        collector.transferOwnership(newOwner);
        // Ownership not yet transferred.
        assertEq(collector.owner(), owner, "owner unchanged before accept");
        assertEq(collector.pendingOwner(), newOwner, "pending owner set");

        // Step 2: new owner accepts.
        vm.prank(newOwner);
        collector.acceptOwnership();
        assertEq(collector.owner(), newOwner, "owner rotated after accept");
        assertEq(collector.pendingOwner(), address(0), "pending cleared");
    }

    function test_RevertWhen_Ownable2Step_NonPendingAccept() public {
        vm.prank(owner);
        collector.transferOwnership(alice);

        // Bob is not the pending owner.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        collector.acceptOwnership();
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Cold / warm gas pin (NOTIFY_GAS_LIMIT regression guard)
    //
    // Pins the legitimate notifyFees workload below the cap-headroom (80K). If a future
    // change pushes the cold path above this, calibration must be revisited and the cap
    // potentially bumped.
    // ──────────────────────────────────────────────────────────────────────────

    function test_NotifyFees_ColdPath_FitsUnderCapHeadroom() public {
        vm.prank(feeDistributorA);
        uint256 gasBefore = gasleft();
        collector.notifyFees(address(tokenA), 1e18);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("notifyFees cold gas", gasUsed);
        assertLt(
            gasUsed, NOTIFY_GAS_HEADROOM_CEILING, "cold notifyFees must fit under NOTIFY_GAS_LIMIT - HEADROOM"
        );
    }

    function test_NotifyFees_WarmPath_FitsUnderCapHeadroom() public {
        // Warm the path with a first call, then measure the second.
        vm.prank(feeDistributorA);
        collector.notifyFees(address(tokenA), 1e18);

        vm.prank(feeDistributorA);
        uint256 gasBefore = gasleft();
        collector.notifyFees(address(tokenA), 2e18);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("notifyFees warm gas", gasUsed);
        assertLt(
            gasUsed, NOTIFY_GAS_HEADROOM_CEILING, "warm notifyFees must fit under NOTIFY_GAS_LIMIT - HEADROOM"
        );
    }

    /// @notice End-to-end: the production `_forwardThirdParty` call shape is
    ///         `notifyFees{gas: NOTIFY_GAS_LIMIT}(...)`. This test enforces that a fresh,
    ///         legitimate cold-path call against the REAL collector succeeds under exactly
    ///         that budget — so the cap is provably sufficient for real recipients, not just
    ///         the mocks the FeeDistributor regression tests use.
    function test_NotifyFees_ColdPath_SucceedsUnderProductionCap() public {
        uint256 productionCap = 150_000; // mirrors FeeDistributor.NOTIFY_GAS_LIMIT
        vm.prank(feeDistributorA);
        collector.notifyFees{gas: productionCap}(address(tokenA), 1e18);
        assertTrue(collector.isTracked(address(tokenA)), "cold notifyFees must succeed under cap");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────────────────────

    function _registerAndFund(MockBoardwalkToken t, address fd, uint256 amount) internal {
        // Register the token (notifyFees gate requires msg.sender == t.feeDistributor()).
        vm.prank(fd);
        collector.notifyFees(address(t), amount);
        // Fund the collector with `amount` of the token.
        t.mint(address(collector), amount);
    }
}

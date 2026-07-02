// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IntegratorFeeCollector} from "src/core/IntegratorFeeCollector.sol";

// ────────────────────────────────────────────────────────────────────────────
//  Mocks
// ────────────────────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor() ERC20("M", "M") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @dev A mock that pretends to be a launched BoardwalkToken (responds to feeDistributor()).
contract MockLaunchToken is ERC20 {
    address public feeDistributor;

    constructor(
        address _fd
    ) ERC20("LaunchT", "LT") {
        feeDistributor = _fd;
    }

    function setFeeDistributor(
        address _fd
    ) external {
        feeDistributor = _fd;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

contract MockFactory {
    mapping(address => bool) public isLaunchToken;
    address public INTEGRATOR_COLLECTOR;

    function setLaunchToken(
        address token,
        bool ok
    ) external {
        isLaunchToken[token] = ok;
    }

    function setIntegratorCollector(
        address c
    ) external {
        INTEGRATOR_COLLECTOR = c;
    }
}

/// @dev Minimal V2 router mock: 1:1 swap from path[0] → RAISE_TOKEN. `getAmountsOut` returns
///      `amountIn` as both the input and output. Configurable to revert or under-deliver.
contract MockRouter {
    address public RAISE_TOKEN_ADDR;
    bool public quoteReverts;
    uint256 public outputMultiplier = 1; // amountOut = amountIn * outputMultiplier
    mapping(address => bool) public quoteRevertsOverride;
    mapping(address => bool) public quoteRevertsOverrideSet;

    constructor(
        address _raiseToken
    ) {
        RAISE_TOKEN_ADDR = _raiseToken;
    }

    function setQuoteReverts(
        bool v
    ) external {
        quoteReverts = v;
    }

    function setQuoteRevertsForToken(
        address token,
        bool v
    ) external {
        quoteRevertsOverride[token] = v;
        quoteRevertsOverrideSet[token] = true;
    }

    function setOutputMultiplier(
        uint256 m
    ) external {
        outputMultiplier = m;
    }

    function factory() external pure returns (address) {
        return address(0);
    }

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts) {
        bool shouldRevert = quoteRevertsOverrideSet[path[0]] ? quoteRevertsOverride[path[0]] : quoteReverts;
        if (shouldRevert) revert("QUOTE_REVERT");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[1] = amountIn * outputMultiplier;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "EXPIRED");
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * outputMultiplier;
        require(out >= amountOutMin, "SLIPPAGE");
        MockERC20(path[1]).mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}

// ────────────────────────────────────────────────────────────────────────────
//  Setup helpers
// ────────────────────────────────────────────────────────────────────────────

abstract contract Base is Test {
    MockERC20 internal raiseToken;
    MockRouter internal router;
    MockFactory internal factory;
    MockLaunchToken internal launchToken;

    address internal owner;
    address internal feeDistributor;
    address internal alice;
    address internal bob;
    address internal carol;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public virtual {
        owner = makeAddr("owner");
        feeDistributor = makeAddr("feeDistributor");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        raiseToken = new MockERC20();
        router = new MockRouter(address(raiseToken));
        factory = new MockFactory();
        launchToken = new MockLaunchToken(feeDistributor);
    }

    /// @dev Deploys a collector with a default 3-slot config: alice/bob/carol with [50%, 30%, 20%].
    function _deploy3Slot() internal returns (IntegratorFeeCollector c) {
        address[] memory addrs = new address[](3);
        addrs[0] = alice;
        addrs[1] = bob;
        addrs[2] = carol;
        uint256[] memory splits = new uint256[](3);
        splits[0] = 5000;
        splits[1] = 3000;
        splits[2] = 2000;
        c = new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
        // setFactory now requires the factory to point back at the collector.
        factory.setIntegratorCollector(address(c));
        vm.prank(owner);
        c.setFactory(address(factory));

        // Mark the launch token as a launch token so receiveFees passes.
        factory.setLaunchToken(address(launchToken), true);
    }

    /// @dev Pranks `feeDistributor` to call `receiveFees(launchToken, amount)`. Mints + approves first.
    function _receiveFees(
        IntegratorFeeCollector c,
        uint256 amount
    ) internal {
        launchToken.mint(feeDistributor, amount);
        vm.prank(feeDistributor);
        launchToken.approve(address(c), amount);
        vm.prank(feeDistributor);
        c.receiveFees(address(launchToken), amount);
    }
}

// ────────────────────────────────────────────────────────────────────────────
//  Constructor validation
// ────────────────────────────────────────────────────────────────────────────

contract Constructor is Base {
    address[] internal addrs;
    uint256[] internal splits;

    function _setOneSlot() internal {
        addrs = new address[](1);
        addrs[0] = alice;
        splits = new uint256[](1);
        splits[0] = 10_000;
    }

    function test_Construct_OneSlot_Success() public {
        _setOneSlot();
        IntegratorFeeCollector c =
            new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
        assertEq(c.slotCount(), 1);
        assertEq(c.integrators(0), alice);
        assertEq(c.integratorSplits(0), 10_000);
        assertEq(c.RAISE_TOKEN(), address(raiseToken));
        assertEq(c.ROUTER(), address(router));
        assertEq(c.factory(), address(0));
        assertEq(c.owner(), owner);
        assertTrue(c.isIntegrator(alice));
        assertEq(c.slotOf(alice), 0);
    }

    function test_RevertWhen_RaiseTokenZero() public {
        _setOneSlot();
        vm.expectRevert(IntegratorFeeCollector.ZeroAddress.selector);
        new IntegratorFeeCollector(owner, address(0), address(router), addrs, splits);
    }

    function test_RevertWhen_RouterZero() public {
        _setOneSlot();
        vm.expectRevert(IntegratorFeeCollector.ZeroAddress.selector);
        new IntegratorFeeCollector(owner, address(raiseToken), address(0), addrs, splits);
    }

    function test_RevertWhen_EmptyArrays() public {
        addrs = new address[](0);
        splits = new uint256[](0);
        vm.expectRevert(IntegratorFeeCollector.EmptyArray.selector);
        new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
    }

    function test_RevertWhen_LengthMismatch() public {
        addrs = new address[](2);
        addrs[0] = alice;
        addrs[1] = bob;
        splits = new uint256[](1);
        splits[0] = 10_000;
        vm.expectRevert(IntegratorFeeCollector.ArrayLengthMismatch.selector);
        new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
    }

    function test_RevertWhen_ZeroIntegratorAddress() public {
        addrs = new address[](2);
        addrs[0] = alice;
        addrs[1] = address(0);
        splits = new uint256[](2);
        splits[0] = 5000;
        splits[1] = 5000;
        vm.expectRevert(IntegratorFeeCollector.ZeroAddress.selector);
        new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
    }

    function test_RevertWhen_ZeroSplit() public {
        addrs = new address[](2);
        addrs[0] = alice;
        addrs[1] = bob;
        splits = new uint256[](2);
        splits[0] = 10_000;
        splits[1] = 0;
        vm.expectRevert(IntegratorFeeCollector.ZeroSplit.selector);
        new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
    }

    function test_RevertWhen_DuplicateIntegrator() public {
        addrs = new address[](2);
        addrs[0] = alice;
        addrs[1] = alice;
        splits = new uint256[](2);
        splits[0] = 5000;
        splits[1] = 5000;
        vm.expectRevert(IntegratorFeeCollector.DuplicateIntegrator.selector);
        new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
    }

    function test_RevertWhen_SplitsNotSum10000() public {
        addrs = new address[](2);
        addrs[0] = alice;
        addrs[1] = bob;
        splits = new uint256[](2);
        splits[0] = 5000;
        splits[1] = 4000; // sums to 9000
        vm.expectRevert(IntegratorFeeCollector.InvalidSplitsSum.selector);
        new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
    }
}

// ────────────────────────────────────────────────────────────────────────────
//  setFactory (Ownable2Step + one-shot)
// ────────────────────────────────────────────────────────────────────────────

contract SetFactory is Base {
    IntegratorFeeCollector internal c;

    function setUp() public override {
        super.setUp();
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10_000;
        c = new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
        // Pre-wire the factory's reverse-pointer for happy-path tests.
        factory.setIntegratorCollector(address(c));
    }

    function test_SetFactory_Success() public {
        vm.expectEmit(true, false, false, true);
        emit IntegratorFeeCollector.FactorySet(address(factory));
        vm.prank(owner);
        c.setFactory(address(factory));
        assertEq(c.factory(), address(factory));
    }

    function test_RevertWhen_SetFactory_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        c.setFactory(address(factory));
    }

    function test_RevertWhen_SetFactory_Twice() public {
        vm.prank(owner);
        c.setFactory(address(factory));
        // Second call uses an unrelated contract so the FactoryAlreadySet guard fires before any
        // would-be FactoryMismatch / NotAContract / ZeroAddress check.
        vm.expectRevert(IntegratorFeeCollector.FactoryAlreadySet.selector);
        vm.prank(owner);
        c.setFactory(address(factory));
    }

    function test_RevertWhen_SetFactory_Zero() public {
        vm.expectRevert(IntegratorFeeCollector.ZeroAddress.selector);
        vm.prank(owner);
        c.setFactory(address(0));
    }

    function test_RevertWhen_SetFactory_NotAContract() public {
        // EOA target — `_factory.code.length == 0`.
        vm.expectRevert(IntegratorFeeCollector.NotAContract.selector);
        vm.prank(owner);
        c.setFactory(makeAddr("someEoa"));
    }

    function test_RevertWhen_SetFactory_FactoryMismatch() public {
        // Factory does not point back at THIS collector — its `INTEGRATOR_COLLECTOR()` returns
        // address(0) (or some other address), so the binding check rejects.
        MockFactory wrongFactory = new MockFactory();
        // wrongFactory.INTEGRATOR_COLLECTOR() == address(0), not address(c).
        vm.expectRevert(IntegratorFeeCollector.FactoryMismatch.selector);
        vm.prank(owner);
        c.setFactory(address(wrongFactory));
    }

    function test_SetFactory_PostRenounce_PermanentlyInert() public {
        vm.prank(owner);
        c.renounceOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        c.setFactory(address(factory));
    }

    function test_TransferOwnership_TwoStep() public {
        vm.prank(owner);
        c.transferOwnership(alice);
        // pendingOwner is now alice; she must accept
        assertEq(c.pendingOwner(), alice);
        vm.prank(alice);
        c.acceptOwnership();
        assertEq(c.owner(), alice);

        // Now alice can call setFactory.
        vm.prank(alice);
        c.setFactory(address(factory));
        assertEq(c.factory(), address(factory));
    }
}

// ────────────────────────────────────────────────────────────────────────────
//  receiveFees gating
// ────────────────────────────────────────────────────────────────────────────

contract ReceiveFees is Base {
    function test_ReceiveFees_Success_AllocatesAcrossSlots() public {
        IntegratorFeeCollector c = _deploy3Slot();
        _receiveFees(c, 1000);

        // Splits [5000, 3000, 2000] of 1000 = [500, 300, 200]
        (uint256 a0,,,) = c.claimStates(0, address(launchToken));
        (uint256 a1,,,) = c.claimStates(1, address(launchToken));
        (uint256 a2,,,) = c.claimStates(2, address(launchToken));
        assertEq(a0, 500);
        assertEq(a1, 300);
        assertEq(a2, 200); // last slot includes any rounding remainder

        assertTrue(c.isTracked(alice, address(launchToken)));
        assertTrue(c.isTracked(bob, address(launchToken)));
        assertTrue(c.isTracked(carol, address(launchToken)));
        assertEq(IERC20(launchToken).balanceOf(address(c)), 1000);
    }

    function test_ReceiveFees_LastSlotAbsorbsRoundingRemainder() public {
        IntegratorFeeCollector c = _deploy3Slot();
        // 1003 / [5000, 3000, 2000]: 501.5/300.9/200.6 → 501/300/202 (last absorbs +2)
        _receiveFees(c, 1003);
        (uint256 a0,,,) = c.claimStates(0, address(launchToken));
        (uint256 a1,,,) = c.claimStates(1, address(launchToken));
        (uint256 a2,,,) = c.claimStates(2, address(launchToken));
        assertEq(a0 + a1 + a2, 1003, "all dust accounted for");
        assertEq(a2, 1003 - a0 - a1);
    }

    function test_RevertWhen_ReceiveFees_FactoryUnset() public {
        // Build collector but DON'T setFactory.
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10_000;
        IntegratorFeeCollector c =
            new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
        factory.setLaunchToken(address(launchToken), true);

        launchToken.mint(feeDistributor, 100);
        vm.prank(feeDistributor);
        launchToken.approve(address(c), 100);
        vm.prank(feeDistributor);
        vm.expectRevert(IntegratorFeeCollector.UnknownSender.selector);
        c.receiveFees(address(launchToken), 100);
    }

    function test_RevertWhen_ReceiveFees_NotALaunchToken() public {
        IntegratorFeeCollector c = _deploy3Slot();
        // Token not registered with factory
        MockLaunchToken otherToken = new MockLaunchToken(feeDistributor);
        // factory.isLaunchToken(otherToken) defaults to false

        otherToken.mint(feeDistributor, 100);
        vm.prank(feeDistributor);
        otherToken.approve(address(c), 100);
        vm.prank(feeDistributor);
        vm.expectRevert(IntegratorFeeCollector.UnknownToken.selector);
        c.receiveFees(address(otherToken), 100);
    }

    function test_RevertWhen_ReceiveFees_WrongFeeDistributor() public {
        IntegratorFeeCollector c = _deploy3Slot();
        // Token reports a different feeDistributor than msg.sender
        launchToken.setFeeDistributor(address(0xdeadbeef));
        launchToken.mint(feeDistributor, 100);
        vm.prank(feeDistributor);
        launchToken.approve(address(c), 100);
        vm.prank(feeDistributor);
        vm.expectRevert(IntegratorFeeCollector.UnknownSender.selector);
        c.receiveFees(address(launchToken), 100);
    }

    function test_ReceiveFees_ZeroAmount_NoOp() public {
        IntegratorFeeCollector c = _deploy3Slot();
        // No mint/approve needed - amount 0 short-circuits
        vm.prank(feeDistributor);
        c.receiveFees(address(launchToken), 0);
        assertEq(IERC20(launchToken).balanceOf(address(c)), 0);
        assertFalse(c.isTracked(alice, address(launchToken)));
    }
}

// ────────────────────────────────────────────────────────────────────────────
//  claimableAmount math (mirrors issuer with /4)
// ────────────────────────────────────────────────────────────────────────────

contract ClaimableMath is Base {
    IntegratorFeeCollector internal c;

    function setUp() public override {
        super.setUp();
        c = _deploy3Slot();
    }

    function test_Claimable_BeforeAccrual_Zero() public {
        assertEq(c.claimableAmount(alice, address(launchToken)), 0);
    }

    function test_Claimable_FirstClaim_25Percent() public {
        // Slot 0 (alice) gets 50% of 4000 = 2000. Cap = 2000/4 = 500.
        _receiveFees(c, 4000);
        assertEq(c.claimableAmount(alice, address(launchToken)), 500);
    }

    function test_Claimable_DustEscape() public {
        // totalAccrued < 4 means cap rounds to 0; full unclaimed should be claimable.
        // Slot 0 gets 50% of 6 = 3. Cap = 3/4 = 0 → return unclaimed (3).
        _receiveFees(c, 6);
        assertEq(c.claimableAmount(alice, address(launchToken)), 3);
    }

    function test_Claimable_PartialClaim_RemainingInWindow() public {
        _receiveFees(c, 4000);
        // alice cap = 500. Claim partially — first claim consumes the cap; subsequent in same
        // window should be 0 even though there's unclaimed.
        vm.prank(alice);
        c.claim(address(launchToken), 0, block.timestamp + 1);
        assertEq(c.claimableAmount(alice, address(launchToken)), 0, "rate limit consumed");
    }

    function test_Claimable_AfterWindow_Reset() public {
        _receiveFees(c, 4000);
        vm.prank(alice);
        c.claim(address(launchToken), 0, block.timestamp + 1);
        // Warp 1 day + 1 second past lastClaimTime
        vm.warp(block.timestamp + 1 days + 1);
        // Cap = unclaimed / 4. alice's slot accrued 2000 (50% of 4000); first claim took 500;
        // unclaimed = 1500; new cap = 375.
        assertEq(c.claimableAmount(alice, address(launchToken)), 375);
    }
}

// ────────────────────────────────────────────────────────────────────────────
//  claim
// ────────────────────────────────────────────────────────────────────────────

contract ClaimSingular is Base {
    IntegratorFeeCollector internal c;

    function setUp() public override {
        super.setUp();
        c = _deploy3Slot();
        _receiveFees(c, 4000); // alice = 2000 accrued, 500 claimable
    }

    function test_Claim_Success_SwapsAndUpdatesState() public {
        uint256 raiseBefore = raiseToken.balanceOf(alice);
        vm.prank(alice);
        c.claim(address(launchToken), 500, block.timestamp + 1);
        assertEq(raiseToken.balanceOf(alice) - raiseBefore, 500); // 1:1 router
        // claimed = 500, accrued = 2000 → still tracked
        assertTrue(c.isTracked(alice, address(launchToken)));
    }

    function test_RevertWhen_Claim_NotIntegrator() public {
        vm.expectRevert(IntegratorFeeCollector.NotIntegrator.selector);
        vm.prank(makeAddr("randomUser"));
        c.claim(address(launchToken), 0, block.timestamp + 1);
    }

    function test_RevertWhen_Claim_NothingToClaim() public {
        vm.prank(alice);
        c.claim(address(launchToken), 0, block.timestamp + 1);
        // Window not elapsed, claimable now 0
        vm.expectRevert(IntegratorFeeCollector.NothingToClaimYet.selector);
        vm.prank(alice);
        c.claim(address(launchToken), 0, block.timestamp + 1);
    }

    function test_RevertWhen_Claim_SlippageExceeded() public {
        vm.prank(alice);
        vm.expectRevert("SLIPPAGE");
        c.claim(address(launchToken), 1000, block.timestamp + 1); // expects 500 out, demands 1000
        // State must be untouched (claim attempt failed)
        assertEq(c.claimableAmount(alice, address(launchToken)), 500);
    }

    function test_Claim_FullExhaustion_RemovesFromSet() public {
        // accrued = 2000. Cap = unclaimed / 4, so each window claims 25% of the live remainder
        // (500, 375, 281, 211, ...) until `unclaimed < 4` triggers the dust escape. Loop with
        // a generous upper bound and break on exhaustion.
        uint256 startTime = block.timestamp;
        uint256 maxWindows = 30;
        bool exhausted;
        for (uint256 i = 0; i < maxWindows; i++) {
            uint256 claimable = c.claimableAmount(alice, address(launchToken));
            if (claimable == 0) {
                exhausted = true;
                break;
            }
            vm.prank(alice);
            c.claim(address(launchToken), 0, type(uint256).max);
            vm.warp(startTime + (i + 1) * (1 days + 1));
        }
        assertTrue(exhausted, "exhausted within bounded windows");
        assertEq(c.claimableAmount(alice, address(launchToken)), 0);
        assertFalse(c.isTracked(alice, address(launchToken)), "exhausted token removed from set");
    }

    function test_Claim_Reaccrual_AfterFullExhaustion() public {
        uint256 startTime = block.timestamp;
        for (uint256 i = 0; i < 30; i++) {
            uint256 claimable = c.claimableAmount(alice, address(launchToken));
            if (claimable == 0) break;
            vm.prank(alice);
            c.claim(address(launchToken), 0, type(uint256).max);
            vm.warp(startTime + (i + 1) * (1 days + 1));
        }
        assertFalse(c.isTracked(alice, address(launchToken)));
        // After full drain `unclaimed == 0`. A fresh receiveFees(4000) adds alice's 50% slot
        // share = 2000 unclaimed; new cap = 2000 / 4 = 500.
        _receiveFees(c, 4000);
        assertTrue(c.isTracked(alice, address(launchToken)));
        assertEq(c.claimableAmount(alice, address(launchToken)), 500);
    }

    /// @notice Under steady recurring accruals the cap stays bounded by `unclaimed / 4` and
    ///         does not inflate from the lifetime totalAccrued history.
    function test_RateLimit_SteadyInflow_DoesNotInflateWithHistory() public {
        // setUp already ran _receiveFees(c, 4000) (alice slot = 2000 accrued).
        uint256 dailyAccrual = 100; // alice's slot share = 50/day at 5000 BPS

        uint256 startTime = block.timestamp;
        uint256 totalClaimed;
        uint256 maxCapEver;

        for (uint256 i = 0; i < 30; i++) {
            vm.warp(startTime + i * (1 days + 1));
            _receiveFees(c, dailyAccrual);

            (uint256 totalAccrued, uint256 claimedSoFar,,) = c.claimStates(0, address(launchToken));
            uint256 unclaimed = totalAccrued - claimedSoFar;
            uint256 cap = c.claimableAmount(alice, address(launchToken));

            if (unclaimed >= 4) {
                assertLe(cap, unclaimed / 4, "cap exceeds live unclaimed/4");
            }
            assertLe(cap, unclaimed, "cap exceeds unclaimed");

            if (cap > maxCapEver) maxCapEver = cap;

            if (cap > 0) {
                vm.prank(alice);
                c.claim(address(launchToken), 0, type(uint256).max);
                totalClaimed += cap;
            }
        }

        // After 30 days at 50/day, lifetime totalAccrued ≈ 3500. A `totalAccrued / 4` cap
        // would read ~875, well above the 50/day inflow. Live `unclaimed / 4` keeps the cap
        // bounded by the rolling backlog (~4 * dailyAccrual).
        assertLt(maxCapEver, 700, "cap inflated with history");
    }
}

// ────────────────────────────────────────────────────────────────────────────
//  claimBatch + isolation
// ────────────────────────────────────────────────────────────────────────────

contract ClaimBatch is Base {
    IntegratorFeeCollector internal c;
    MockLaunchToken internal token2;
    MockLaunchToken internal token3;

    function setUp() public override {
        super.setUp();
        c = _deploy3Slot();
        token2 = new MockLaunchToken(feeDistributor);
        token3 = new MockLaunchToken(feeDistributor);
        factory.setLaunchToken(address(token2), true);
        factory.setLaunchToken(address(token3), true);

        // Accrue fees on three tokens for slot 0 (alice)
        _receive(c, address(launchToken), 4000); // alice = 2000 → 500 claimable
        _receive(c, address(token2), 4000);
        _receive(c, address(token3), 4000);
    }

    function _receive(
        IntegratorFeeCollector col,
        address tk,
        uint256 amt
    ) internal {
        MockLaunchToken(tk).mint(feeDistributor, amt);
        vm.prank(feeDistributor);
        IERC20(tk).approve(address(col), amt);
        vm.prank(feeDistributor);
        col.receiveFees(tk, amt);
    }

    function test_ClaimBatch_AllSucceed() public {
        address[] memory toks = new address[](3);
        toks[0] = address(launchToken);
        toks[1] = address(token2);
        toks[2] = address(token3);
        uint256[] memory mins = new uint256[](3);
        mins[0] = 500;
        mins[1] = 500;
        mins[2] = 500;
        vm.prank(alice);
        c.claimBatch(toks, mins, block.timestamp + 1);
        assertEq(raiseToken.balanceOf(alice), 1500);
    }

    function test_RevertWhen_ClaimBatch_LengthMismatch() public {
        address[] memory toks = new address[](2);
        toks[0] = address(launchToken);
        toks[1] = address(token2);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 0;
        vm.prank(alice);
        vm.expectRevert(IntegratorFeeCollector.ArrayLengthMismatch.selector);
        c.claimBatch(toks, mins, block.timestamp + 1);
    }

    function test_RevertWhen_ClaimBatch_Empty() public {
        address[] memory toks = new address[](0);
        uint256[] memory mins = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(IntegratorFeeCollector.EmptyArray.selector);
        c.claimBatch(toks, mins, block.timestamp + 1);
    }

    function test_ClaimBatch_OneTokenFails_OthersSucceed_RateLimitUntouched() public {
        // Force a slippage failure on token2 by demanding minOut > 500 (router gives 500)
        address[] memory toks = new address[](3);
        toks[0] = address(launchToken);
        toks[1] = address(token2); // forced fail
        toks[2] = address(token3);
        uint256[] memory mins = new uint256[](3);
        mins[0] = 500;
        mins[1] = 1000; // > 500 → SLIPPAGE → catch
        mins[2] = 500;

        vm.expectEmit(true, true, false, true, address(c));
        emit IntegratorFeeCollector.ClaimFailed(0, address(token2));
        vm.prank(alice);
        c.claimBatch(toks, mins, block.timestamp + 1);

        // tok1 + tok3 succeeded (1000 raise total)
        assertEq(raiseToken.balanceOf(alice), 1000);
        // token2 rate limit untouched: still claimable
        assertEq(c.claimableAmount(alice, address(token2)), 500);
        // token2 stays tracked
        assertTrue(c.isTracked(alice, address(token2)));
    }

    function test_ClaimBatch_RateLimitWindowSkipped_SilentlyNoEvent() public {
        // First claim exhausts the rate-limit window for token1
        address[] memory toks1 = new address[](1);
        toks1[0] = address(launchToken);
        uint256[] memory mins1 = new uint256[](1);
        mins1[0] = 0;
        vm.prank(alice);
        c.claimBatch(toks1, mins1, block.timestamp + 1);

        // Now claim again in batch with all three tokens. token1 is rate-limited (claimable=0),
        // token2 and token3 should succeed. No ClaimFailed event for token1.
        address[] memory toks = new address[](3);
        toks[0] = address(launchToken);
        toks[1] = address(token2);
        toks[2] = address(token3);
        uint256[] memory mins = new uint256[](3);

        vm.recordLogs();
        vm.prank(alice);
        c.claimBatch(toks, mins, block.timestamp + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Look for ClaimFailed on launchToken — should not exist
        bytes32 claimFailedSig = keccak256("ClaimFailed(uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == claimFailedSig) {
                // topic[2] is indexed token
                assertTrue(
                    address(uint160(uint256(logs[i].topics[2]))) != address(launchToken),
                    "rate-limited token must NOT emit ClaimFailed"
                );
            }
        }
    }

    function test_ClaimBatch_UntrackedToken_SilentSkip() public {
        MockLaunchToken untracked = new MockLaunchToken(feeDistributor);
        factory.setLaunchToken(address(untracked), true);
        // No fees accrued for `untracked` in slot 0, so claimable = 0 → silent skip.
        address[] memory toks = new address[](1);
        toks[0] = address(untracked);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 0;
        vm.recordLogs();
        vm.prank(alice);
        c.claimBatch(toks, mins, block.timestamp + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 claimFailedSig = keccak256("ClaimFailed(uint256,address)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == claimFailedSig) {
                assertTrue(false, "untracked token should not emit ClaimFailed");
            }
        }
    }

    function test_RevertWhen_ClaimBatch_NotIntegrator() public {
        address[] memory toks = new address[](1);
        toks[0] = address(launchToken);
        uint256[] memory mins = new uint256[](1);
        vm.expectRevert(IntegratorFeeCollector.NotIntegrator.selector);
        vm.prank(makeAddr("notRegistered"));
        c.claimBatch(toks, mins, block.timestamp + 1);
    }

    function test_RevertWhen_ClaimOneToken_DirectExternalCall() public {
        vm.expectRevert(IntegratorFeeCollector.OnlySelf.selector);
        vm.prank(alice);
        c._claimOneToken(0, address(launchToken), 0, block.timestamp + 1);
    }
}

// ────────────────────────────────────────────────────────────────────────────
//  Slot rotation (signal/execute/cancel) + invariants
// ────────────────────────────────────────────────────────────────────────────

contract Rotation is Base {
    IntegratorFeeCollector internal c;
    address internal newAlice;

    function setUp() public override {
        super.setUp();
        c = _deploy3Slot();
        newAlice = makeAddr("newAlice");
        _receiveFees(c, 4000);
    }

    function test_Signal_Then_Execute_RotatesAddress() public {
        vm.prank(alice);
        c.signalChangeAddress(newAlice);

        // Cannot execute before delay
        vm.expectRevert();
        c.executeChangeAddress(0, newAlice);

        vm.warp(block.timestamp + c.ROTATION_DELAY());
        vm.prank(makeAddr("randomCaller")); // permissionless
        c.executeChangeAddress(0, newAlice);

        assertEq(c.integrators(0), newAlice);
        assertTrue(c.isIntegrator(newAlice));
        assertFalse(c.isIntegrator(alice));
        assertEq(c.slotOf(newAlice), 0);
    }

    function test_PostRotation_NewAddressClaims_OldReverts() public {
        vm.prank(alice);
        c.signalChangeAddress(newAlice);
        vm.warp(block.timestamp + c.ROTATION_DELAY());
        c.executeChangeAddress(0, newAlice);

        // alice can no longer claim (NotIntegrator)
        vm.expectRevert(IntegratorFeeCollector.NotIntegrator.selector);
        vm.prank(alice);
        c.claim(address(launchToken), 0, block.timestamp + 1);

        // newAlice inherits the slot's accrual and can claim
        vm.prank(newAlice);
        c.claim(address(launchToken), 0, block.timestamp + 1);
        assertEq(raiseToken.balanceOf(newAlice), 500);
    }

    function test_RevertWhen_ExecuteChangeAddress_ZeroNewAddress() public {
        vm.prank(alice);
        c.signalChangeAddress(address(0));
        vm.warp(block.timestamp + c.ROTATION_DELAY());
        vm.expectRevert(IntegratorFeeCollector.ZeroAddress.selector);
        c.executeChangeAddress(0, address(0));
    }

    function test_RevertWhen_ExecuteChangeAddress_NewAddressAlreadyAnIntegrator() public {
        // alice tries to rotate to bob, who is slot 1
        vm.prank(alice);
        c.signalChangeAddress(bob);
        vm.warp(block.timestamp + c.ROTATION_DELAY());
        vm.expectRevert(IntegratorFeeCollector.DuplicateAddress.selector);
        c.executeChangeAddress(0, bob);
    }

    function test_RevertWhen_ExecuteChangeAddress_InvalidSlot() public {
        vm.expectRevert(IntegratorFeeCollector.InvalidSlot.selector);
        c.executeChangeAddress(99, newAlice);
    }

    function test_RevertWhen_SignalChangeAddress_NotIntegrator() public {
        vm.expectRevert(IntegratorFeeCollector.NotIntegrator.selector);
        vm.prank(makeAddr("randomUser"));
        c.signalChangeAddress(newAlice);
    }

    function test_CancelChangeAddress_ClearsPendingChange() public {
        vm.prank(alice);
        c.signalChangeAddress(newAlice);
        vm.prank(alice);
        c.cancelChangeAddress();
        // After cancel, execute reverts (no pending)
        vm.warp(block.timestamp + c.ROTATION_DELAY());
        vm.expectRevert(); // TimelockNotSignaled
        c.executeChangeAddress(0, newAlice);
    }

    function test_RotationDelay_Is14Days() public {
        assertEq(c.ROTATION_DELAY(), 14 days);
    }

    function test_GenericSignalAction_AlwaysReverts() public {
        // Cache the action hash before vm.expectRevert so the view call doesn't consume the expectation.
        bytes32 action = c.ACTION_CHANGE_ADDRESS();
        vm.prank(owner);
        vm.expectRevert(IntegratorFeeCollector.NotAuthorized.selector);
        c.signalAction(action, keccak256("anything"));
    }
}

// ────────────────────────────────────────────────────────────────────────────
//  Discovery & quoting
// ────────────────────────────────────────────────────────────────────────────

contract Discovery is Base {
    IntegratorFeeCollector internal c;
    MockLaunchToken internal token2;

    function setUp() public override {
        super.setUp();
        c = _deploy3Slot();
        token2 = new MockLaunchToken(feeDistributor);
        factory.setLaunchToken(address(token2), true);

        _receiveFees(c, 4000);
        _receive(c, address(token2), 4000);
    }

    function _receive(
        IntegratorFeeCollector col,
        address tk,
        uint256 amt
    ) internal {
        MockLaunchToken(tk).mint(feeDistributor, amt);
        vm.prank(feeDistributor);
        IERC20(tk).approve(address(col), amt);
        vm.prank(feeDistributor);
        col.receiveFees(tk, amt);
    }

    function test_TrackedTokens_ReturnsFullSet() public {
        address[] memory tokens = c.trackedTokens(alice);
        assertEq(tokens.length, 2);
    }

    function test_QuoteSingular_ZeroClaimable_Returns_0_0() public {
        MockLaunchToken untracked = new MockLaunchToken(feeDistributor);
        (uint256 amountIn, uint256 minOut) = c.quote(alice, address(untracked), 100);
        assertEq(amountIn, 0);
        assertEq(minOut, 0);
    }

    function test_QuoteSingular_NonZero_HappyPath() public {
        // alice's claimable = 500. Router multiplier = 1, so getAmountsOut(500) → 500.
        // slippage 100 BPS (1%) → minOut = 500 * 9900 / 10000 = 495.
        (uint256 amountIn, uint256 minOut) = c.quote(alice, address(launchToken), 100);
        assertEq(amountIn, 500);
        assertEq(minOut, 495);
    }

    function test_RevertWhen_QuoteSingular_RouterReverts() public {
        router.setQuoteReverts(true);
        vm.expectRevert(IntegratorFeeCollector.QuoteFailed.selector);
        c.quote(alice, address(launchToken), 100);
    }

    function test_QuoteBatch_ReturnsParallelArrays() public {
        address[] memory toks = new address[](2);
        toks[0] = address(launchToken);
        toks[1] = address(token2);
        (address[] memory tokensOut, uint256[] memory amountsIn, uint256[] memory minOuts) =
            c.quoteBatch(alice, toks, 100);
        assertEq(tokensOut.length, 2);
        assertEq(tokensOut[0], address(launchToken));
        assertEq(tokensOut[1], address(token2));
        assertEq(amountsIn[0], 500);
        assertEq(amountsIn[1], 500);
        assertEq(minOuts[0], 495);
        assertEq(minOuts[1], 495);
    }

    function test_QuoteBatch_FiltersOutEmptyAndFailedQuotes() public {
        MockLaunchToken untracked = new MockLaunchToken(feeDistributor);
        address[] memory toks = new address[](3);
        toks[0] = address(launchToken);
        toks[1] = address(untracked); // claimable=0 → dropped
        toks[2] = address(token2);
        (address[] memory tokensOut, uint256[] memory amountsIn, uint256[] memory minOuts) =
            c.quoteBatch(alice, toks, 0);
        assertEq(tokensOut.length, 2, "untracked dropped");
        assertEq(tokensOut[0], address(launchToken));
        assertEq(tokensOut[1], address(token2));
        assertEq(amountsIn[0], 500);
        assertEq(amountsIn[1], 500);
        assertEq(minOuts[0], 500);
        assertEq(minOuts[1], 500);
    }

    function test_QuoteBatch_FiltersOutRouterRevertedQuotes() public {
        // launchToken's router quote reverts → dropped from output. token2 still succeeds.
        router.setQuoteReverts(true);
        router.setQuoteRevertsForToken(address(token2), false);

        address[] memory toks = new address[](2);
        toks[0] = address(launchToken);
        toks[1] = address(token2);
        (address[] memory tokensOut, uint256[] memory amountsIn, uint256[] memory minOuts) =
            c.quoteBatch(alice, toks, 0);
        assertEq(tokensOut.length, 1, "router-revert filtered");
        assertEq(tokensOut[0], address(token2));
        assertEq(amountsIn[0], 500);
        assertEq(minOuts[0], 500);
    }
}


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IntegratorFeeCollector} from "src/core/IntegratorFeeCollector.sol";

// ────────────────────────────────────────────────────────────────────────────
//  Local mocks (mirror those in test/unit/IntegratorFeeCollector.t.sol)
// ────────────────────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor() ERC20("M", "M") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockLaunchToken is ERC20 {
    address public feeDistributor;

    constructor(address _fd) ERC20("LT", "LT") {
        feeDistributor = _fd;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockFactory {
    mapping(address => bool) public isLaunchToken;
    address public INTEGRATOR_COLLECTOR;

    function setLaunchToken(address token, bool ok) external {
        isLaunchToken[token] = ok;
    }

    function setIntegratorCollector(address c) external {
        INTEGRATOR_COLLECTOR = c;
    }
}

contract MockRouter {
    address public RAISE_TOKEN_ADDR;

    constructor(address _raiseToken) {
        RAISE_TOKEN_ADDR = _raiseToken;
    }

    function factory() external pure returns (address) {
        return address(0);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        pure
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
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
        require(amountIn >= amountOutMin, "SLIPPAGE");
        MockERC20(path[1]).mint(to, amountIn);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
    }
}

// ────────────────────────────────────────────────────────────────────────────
//  Handler
// ────────────────────────────────────────────────────────────────────────────

/// @title IntegratorFeeCollectorHandler
/// @notice Bounded-action handler driving the IntegratorFeeCollector through realistic state
///         transitions. Tracks ghost variables for cross-checking invariants.
contract IntegratorFeeCollectorHandler is Test {
    IntegratorFeeCollector public collector;
    MockFactory public mockFactory;
    address public feeDistributor;

    /// @dev Fixed set of 3 launch tokens registered with the factory at construction.
    MockLaunchToken[3] public tokens;

    /// @dev Per-token running total of all `receiveFees(token, amount)` amounts ever passed in.
    mapping(address => uint256) public ghost_totalReceivedPerToken;

    /// @dev Pending rotation signals tracked here so executeChangeAddress can be exercised after
    ///      ROTATION_DELAY. Stale entries (overwritten by a later signal for the same slot) will
    ///      simply revert on execute (TimelockDataMismatch) and stay in the array — harmless.
    struct PendingSignal {
        uint256 slotIdx;
        address newAddr;
        uint256 signaledAt;
    }

    PendingSignal[] internal _pendingSignals;

    constructor(
        IntegratorFeeCollector _collector,
        MockFactory _factory,
        address _fd
    ) {
        collector = _collector;
        mockFactory = _factory;
        feeDistributor = _fd;

        for (uint256 i = 0; i < 3; i++) {
            MockLaunchToken token = new MockLaunchToken(_fd);
            _factory.setLaunchToken(address(token), true);
            tokens[i] = token;
        }
    }

    function pendingSignalCount() external view returns (uint256) {
        return _pendingSignals.length;
    }

    // ============ Action functions (fuzzed by Foundry) ============

    function receiveFees(uint256 tokenSeed, uint256 amount) external {
        amount = bound(amount, 0, 1e24);
        if (amount == 0) return;
        MockLaunchToken token = tokens[bound(tokenSeed, 0, 2)];

        token.mint(feeDistributor, amount);
        vm.startPrank(feeDistributor);
        token.approve(address(collector), amount);
        collector.receiveFees(address(token), amount);
        vm.stopPrank();

        ghost_totalReceivedPerToken[address(token)] += amount;
    }

    function claim(uint256 slotSeed, uint256 tokenSeed) external {
        uint256 slotIdx = bound(slotSeed, 0, collector.slotCount() - 1);
        address actor = collector.integrators(slotIdx);
        MockLaunchToken token = tokens[bound(tokenSeed, 0, 2)];

        if (collector.claimableAmount(actor, address(token)) == 0) return;
        vm.prank(actor);
        try collector.claim(address(token), 0, type(uint256).max) {} catch {}
    }

    function claimBatch(uint256 slotSeed) external {
        uint256 slotIdx = bound(slotSeed, 0, collector.slotCount() - 1);
        address actor = collector.integrators(slotIdx);

        address[] memory tokenAddrs = new address[](3);
        uint256[] memory mins = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            tokenAddrs[i] = address(tokens[i]);
        }

        vm.prank(actor);
        try collector.claimBatch(tokenAddrs, mins, type(uint256).max) {} catch {}
    }

    function signalChangeAddress(uint256 slotSeed, uint256 newAddrSeed) external {
        uint256 slotIdx = bound(slotSeed, 0, collector.slotCount() - 1);
        address actor = collector.integrators(slotIdx);

        address newAddr = address(uint160(bound(newAddrSeed, 1, type(uint160).max)));
        // Skip if would revert deterministically inside execute (but signal still succeeds; we
        // just don't want to clutter pendingSignals with guaranteed-fail entries).
        if (collector.isIntegrator(newAddr)) return;
        if (newAddr == address(collector)) return;

        vm.prank(actor);
        try collector.signalChangeAddress(newAddr) {
            _pendingSignals.push(PendingSignal({slotIdx: slotIdx, newAddr: newAddr, signaledAt: block.timestamp}));
        } catch {}
    }

    function executeChangeAddress(uint256 sigSeed) external {
        if (_pendingSignals.length == 0) return;
        uint256 idx = bound(sigSeed, 0, _pendingSignals.length - 1);
        PendingSignal memory sig = _pendingSignals[idx];

        if (block.timestamp < sig.signaledAt + collector.ROTATION_DELAY()) return;
        // Newer signal for the same slot may have made this one stale; skip if newAddr is now
        // taken by another slot (would revert with DuplicateAddress).
        if (collector.isIntegrator(sig.newAddr)) return;

        try collector.executeChangeAddress(sig.slotIdx, sig.newAddr) {
            _pendingSignals[idx] = _pendingSignals[_pendingSignals.length - 1];
            _pendingSignals.pop();
        } catch {}
    }

    function cancelChangeAddress(uint256 slotSeed) external {
        uint256 slotIdx = bound(slotSeed, 0, collector.slotCount() - 1);
        address actor = collector.integrators(slotIdx);
        vm.prank(actor);
        try collector.cancelChangeAddress() {} catch {}
    }

    function warpTime(uint256 secs) external {
        secs = bound(secs, 1, 30 days);
        vm.warp(block.timestamp + secs);
    }
}

// ────────────────────────────────────────────────────────────────────────────
//  Invariant Test Suite
// ────────────────────────────────────────────────────────────────────────────

/// @title IntegratorFeeCollectorInvariantTest
/// @notice Invariant tests for IntegratorFeeCollector. Verifies safety properties that must
///         hold across all reachable states under random sequences of receive / claim /
///         rotate / time-warp actions.
contract IntegratorFeeCollectorInvariantTest is StdInvariant, Test {
    IntegratorFeeCollector internal collector;
    MockERC20 internal raiseToken;
    MockRouter internal router;
    MockFactory internal mockFactory;

    IntegratorFeeCollectorHandler internal handler;

    address internal owner;
    address internal feeDistributor;
    address internal alice;
    address internal bob;
    address internal carol;

    function setUp() public {
        owner = makeAddr("owner");
        feeDistributor = makeAddr("feeDistributor");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");

        raiseToken = new MockERC20();
        router = new MockRouter(address(raiseToken));
        mockFactory = new MockFactory();

        // 3-slot collector with [50%, 30%, 20%] splits.
        address[] memory addrs = new address[](3);
        addrs[0] = alice;
        addrs[1] = bob;
        addrs[2] = carol;
        uint256[] memory splits = new uint256[](3);
        splits[0] = 5000;
        splits[1] = 3000;
        splits[2] = 2000;

        collector = new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
        // Strong factory binding: the factory's INTEGRATOR_COLLECTOR() must point at the collector.
        mockFactory.setIntegratorCollector(address(collector));
        vm.prank(owner);
        collector.setFactory(address(mockFactory));

        handler = new IntegratorFeeCollectorHandler(collector, mockFactory, feeDistributor);

        // Limit fuzzing to the explicit action functions on the handler (excludes auto-generated
        // public state getters and internal helpers).
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = IntegratorFeeCollectorHandler.receiveFees.selector;
        selectors[1] = IntegratorFeeCollectorHandler.claim.selector;
        selectors[2] = IntegratorFeeCollectorHandler.claimBatch.selector;
        selectors[3] = IntegratorFeeCollectorHandler.signalChangeAddress.selector;
        selectors[4] = IntegratorFeeCollectorHandler.executeChangeAddress.selector;
        selectors[5] = IntegratorFeeCollectorHandler.cancelChangeAddress.selector;
        selectors[6] = IntegratorFeeCollectorHandler.warpTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // ============ Helpers ============

    function _slotCount() internal view returns (uint256) {
        return collector.slotCount();
    }

    // ============ Invariants ============

    /// @notice For every (slot, token), the cumulative claimed amount cannot exceed the
    ///         cumulative accrued amount. Enforced by `_claimableBySlot` (returns
    ///         `_min(maxClaimable, unclaimed)`) and the additive update in `_swapAndUpdate`.
    function invariant_TotalClaimedNeverExceedsTotalAccrued() external view {
        uint256 slotCount = _slotCount();
        for (uint256 i = 0; i < slotCount; i++) {
            for (uint256 j = 0; j < 3; j++) {
                MockLaunchToken token = handler.tokens(j);
                (uint256 acc, uint256 claimed,,) = collector.claimStates(i, address(token));
                assertLe(claimed, acc, "totalClaimed > totalAccrued");
            }
        }
    }

    /// @notice For every populated slot `i`, the reverse map resolves the slot's address back
    ///         to `i` (i.e., `_slotPlusOne[integrators[i]] == i + 1`, surfaced as
    ///         `slotOf(integrators[i]) == i`).
    function invariant_ReverseMapInjective() external view {
        uint256 slotCount = _slotCount();
        for (uint256 i = 0; i < slotCount; i++) {
            address slotAddr = collector.integrators(i);
            assertEq(collector.slotOf(slotAddr), i, "reverse map is not injective");
        }
    }

    /// @notice No populated integrator slot ever holds the zero address. Constructor rejects
    ///         it; rotation rejects it via `executeChangeAddress`'s `if (newAddress == address(0))`.
    function invariant_NoZeroAddressInIntegrators() external view {
        uint256 slotCount = _slotCount();
        for (uint256 i = 0; i < slotCount; i++) {
            assertTrue(collector.integrators(i) != address(0), "zero address in integrators");
        }
    }

    /// @notice Every (slot, token) pair in the slot's tracked-token set has positive
    ///         `totalAccrued`. The set is only added to when `share > 0`; on full claim it is
    ///         pruned but `totalAccrued` is not decreased — re-tracking only happens on the
    ///         next non-zero allocation, so the invariant still holds for the post-prune state
    ///         (token is no longer in the set).
    function invariant_TrackedTokensSubsetOfNonZeroAccrual() external view {
        uint256 slotCount = _slotCount();
        for (uint256 i = 0; i < slotCount; i++) {
            address integrator = collector.integrators(i);
            uint256 trackedCount = collector.trackedTokenCount(integrator);
            for (uint256 k = 0; k < trackedCount; k++) {
                address token = collector.trackedTokenAt(integrator, k);
                (uint256 acc,,,) = collector.claimStates(i, token);
                assertGt(acc, 0, "tracked token has zero totalAccrued");
            }
        }
    }

    /// @notice For every token, `sum_i claimStates[i][token].totalAccrued` equals the cumulative
    ///         amount ever passed into `receiveFees(token, _)`. Ensures `_allocate` is
    ///         conservation-of-mass correct (last slot absorbs rounding).
    function invariant_AllocationSumMatches() external view {
        uint256 slotCount = _slotCount();
        for (uint256 j = 0; j < 3; j++) {
            MockLaunchToken token = handler.tokens(j);
            uint256 sum;
            for (uint256 i = 0; i < slotCount; i++) {
                (uint256 acc,,,) = collector.claimStates(i, address(token));
                sum += acc;
            }
            assertEq(
                sum,
                handler.ghost_totalReceivedPerToken(address(token)),
                "sum of slot accruals != cumulative receiveFees"
            );
        }
    }

    /// @notice For any (integrator, token), `claimableAmount` never exceeds the unclaimed
    ///         balance (`totalAccrued - totalClaimed`). Encoded directly in `_claimableBySlot`'s
    ///         `_min(remainingInPeriod, unclaimed)` clause.
    function invariant_ClaimableNeverExceedsAccrued() external view {
        uint256 slotCount = _slotCount();
        for (uint256 i = 0; i < slotCount; i++) {
            address integrator = collector.integrators(i);
            for (uint256 j = 0; j < 3; j++) {
                MockLaunchToken token = handler.tokens(j);
                uint256 claimable = collector.claimableAmount(integrator, address(token));
                (uint256 acc, uint256 claimed,,) = collector.claimStates(i, address(token));
                assertLe(claimable, acc - claimed, "claimable > unclaimed");
            }
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
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

/// @dev A mock that pretends to be a launched BoardwalkToken (responds to feeDistributor()).
contract MockLaunchToken is ERC20 {
    address public feeDistributor;

    constructor(address _fd) ERC20("LaunchT", "LT") {
        feeDistributor = _fd;
    }

    function setFeeDistributor(address _fd) external {
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

/// @dev Minimal V2 router mock: 1:1 swap from path[0] → RAISE_TOKEN. Honors slippage.
contract MockRouter {
    address public RAISE_TOKEN_ADDR;
    bool public quoteReverts;
    uint256 public outputMultiplier = 1; // amountOut = amountIn * outputMultiplier

    constructor(address _raiseToken) {
        RAISE_TOKEN_ADDR = _raiseToken;
    }

    function setQuoteReverts(bool v) external {
        quoteReverts = v;
    }

    function setOutputMultiplier(uint256 m) external {
        outputMultiplier = m;
    }

    function factory() external pure returns (address) {
        return address(0);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        if (quoteReverts) revert("QUOTE_REVERT");
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
//  Fuzz Test Suite
// ────────────────────────────────────────────────────────────────────────────

/// @title IntegratorFeeCollectorFuzzTest
/// @notice Fuzz tests for IntegratorFeeCollector. Complements the example-based unit suite at
///         test/unit/IntegratorFeeCollector.t.sol with property-based coverage of:
///         - allocation arithmetic (sum-conservation, per-slot tolerance)
///         - rate-limit math (cap, dust escape, multi-window respect)
///         - slot rotation (reverse-map injectivity, accrual survival)
///         - claimBatch isolation (rate-limit only consumed for successes)
contract IntegratorFeeCollectorFuzzTest is Test {
    MockERC20 internal raiseToken;
    MockRouter internal router;
    MockFactory internal factory;

    /// @dev launchTokens[0] is aliased as `launchToken` for tests that need only one.
    MockLaunchToken[5] internal launchTokens;
    MockLaunchToken internal launchToken;

    /// @dev Fixed collectors reused across most fuzz tests so setUp deploys are amortized.
    IntegratorFeeCollector internal c1Slot;
    IntegratorFeeCollector internal c3Slot;

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
        factory = new MockFactory();

        for (uint256 i = 0; i < 5; i++) {
            launchTokens[i] = new MockLaunchToken(feeDistributor);
            factory.setLaunchToken(address(launchTokens[i]), true);
        }
        launchToken = launchTokens[0];

        c1Slot = _deploy1SlotCollector();
        c3Slot = _deploy3SlotCollector();
    }

    // ============ Helpers ============

    function _deploy1SlotCollector() internal returns (IntegratorFeeCollector c) {
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        uint256[] memory splits = new uint256[](1);
        splits[0] = 10_000;
        c = new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
        // Strong factory binding: factory's INTEGRATOR_COLLECTOR() must point at THIS collector.
        factory.setIntegratorCollector(address(c));
        vm.prank(owner);
        c.setFactory(address(factory));
    }

    function _deploy3SlotCollector() internal returns (IntegratorFeeCollector c) {
        address[] memory addrs = new address[](3);
        addrs[0] = alice;
        addrs[1] = bob;
        addrs[2] = carol;
        uint256[] memory splits = new uint256[](3);
        splits[0] = 5000;
        splits[1] = 3000;
        splits[2] = 2000;
        c = new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
        factory.setIntegratorCollector(address(c));
        vm.prank(owner);
        c.setFactory(address(factory));
    }

    function _receiveFees(IntegratorFeeCollector c, MockLaunchToken token, uint256 amount) internal {
        token.mint(feeDistributor, amount);
        vm.prank(feeDistributor);
        token.approve(address(c), amount);
        vm.prank(feeDistributor);
        c.receiveFees(address(token), amount);
    }

    // ============ Allocation math ============

    /// @notice Sum of per-slot accruals MUST equal `totalAmount` (last slot absorbs any
    ///         rounding remainder). Splits are constructed to be valid: each in [1, 9996],
    ///         summing exactly to BPS_DENOMINATOR.
    function testFuzz_Allocate_TotalEqualsInput(
        uint256 totalAmount,
        uint256 split0Raw,
        uint256 split1Raw,
        uint256 split2Raw,
        uint256 split3Raw
    ) public {
        totalAmount = bound(totalAmount, 1, 1e30);
        // First 4 splits in [1, 2000] guarantees sum_first4 in [4, 8000], so split[4] in
        // [2000, 9996] (valid: > 0 and entire vector sums to 10000).
        uint256 s0 = bound(split0Raw, 1, 2000);
        uint256 s1 = bound(split1Raw, 1, 2000);
        uint256 s2 = bound(split2Raw, 1, 2000);
        uint256 s3 = bound(split3Raw, 1, 2000);
        uint256 s4 = 10_000 - s0 - s1 - s2 - s3;

        address[] memory addrs = new address[](5);
        addrs[0] = makeAddr("integ0");
        addrs[1] = makeAddr("integ1");
        addrs[2] = makeAddr("integ2");
        addrs[3] = makeAddr("integ3");
        addrs[4] = makeAddr("integ4");
        uint256[] memory splits = new uint256[](5);
        splits[0] = s0;
        splits[1] = s1;
        splits[2] = s2;
        splits[3] = s3;
        splits[4] = s4;

        IntegratorFeeCollector c =
            new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
        factory.setIntegratorCollector(address(c));
        vm.prank(owner);
        c.setFactory(address(factory));

        _receiveFees(c, launchToken, totalAmount);

        uint256 sum;
        for (uint256 i = 0; i < 5; i++) {
            (uint256 acc,,,) = c.claimStates(i, address(launchToken));
            sum += acc;
        }
        assertEq(sum, totalAmount, "sum of slot accruals must equal totalAmount");
        // Sanity: contract holds the same balance.
        assertEq(IERC20(launchToken).balanceOf(address(c)), totalAmount, "contract balance equals total");
    }

    /// @notice For an even split across `slotCount` slots (chosen from divisors of 10000),
    ///         each slot's share is approximately `totalAmount / slotCount` within `slotCount`
    ///         wei. Worst case: floor-rounding loses up to (slotCount - 1) wei across the first
    ///         (slotCount - 1) slots, all of which is absorbed by the last slot.
    function testFuzz_Allocate_PerSlotShareWithinTolerance(
        uint256 totalAmount,
        uint8 slotCountSeed
    ) public {
        // Divisors of 10000 capped at MAX_INTEGRATOR_SLOTS = 5 — beyond that, the constructor
        // rejects with `TooManySlots` (gas DoS guard on the taxed-transfer path).
        uint8[4] memory divisors = [1, 2, 4, 5];
        uint8 slotCount = divisors[bound(slotCountSeed, 0, 3)];
        totalAmount = bound(totalAmount, 1, 1e30);

        address[] memory addrs = new address[](slotCount);
        uint256[] memory splits = new uint256[](slotCount);
        uint256 perSplit = 10_000 / slotCount;
        for (uint256 i = 0; i < slotCount; i++) {
            addrs[i] = makeAddr(string(abi.encodePacked("integ", vm.toString(i))));
            splits[i] = perSplit;
        }

        IntegratorFeeCollector c =
            new IntegratorFeeCollector(owner, address(raiseToken), address(router), addrs, splits);
        factory.setIntegratorCollector(address(c));
        vm.prank(owner);
        c.setFactory(address(factory));

        _receiveFees(c, launchToken, totalAmount);

        uint256 expectedPer = totalAmount / slotCount;
        for (uint256 i = 0; i < slotCount; i++) {
            (uint256 acc,,,) = c.claimStates(i, address(launchToken));
            // Allow up to `slotCount` wei tolerance: per-slot floor-rounding ≤ 1 wei, last
            // slot absorbs (slotCount - 1) wei of remainder in the worst case.
            assertApproxEqAbs(acc, expectedPer, slotCount, "per-slot share within tolerance");
        }
    }

    // ============ Rate limit math ============

    /// @notice Property: `claimableAmount() <= totalAccrued / 4` for any state reached via valid
    ///         actions. We exclude the dust-escape regime (totalAccrued < 4) from this check,
    ///         since `_claimableBySlot` deliberately bypasses the cap there.
    function testFuzz_ClaimableAmount_NeverExceedsCap(
        uint256 totalAccrued,
        uint8 numClaims,
        uint256 timeOffset
    ) public {
        totalAccrued = bound(totalAccrued, 4, 1e30);
        numClaims = uint8(bound(numClaims, 0, 5));
        timeOffset = bound(timeOffset, 0, 365 days);

        _receiveFees(c1Slot, launchToken, totalAccrued);

        for (uint256 i = 0; i < numClaims; i++) {
            uint256 claimable = c1Slot.claimableAmount(alice, address(launchToken));
            if (claimable > 0) {
                vm.prank(alice);
                try c1Slot.claim(address(launchToken), 0, type(uint256).max) {} catch {}
            }
            if (timeOffset > 0) vm.warp(block.timestamp + timeOffset);
        }

        uint256 finalClaimable = c1Slot.claimableAmount(alice, address(launchToken));
        assertLe(finalClaimable, totalAccrued / 4, "claimable exceeds 25% cap");
    }

    /// @notice When `totalAccrued < 4` (cap rounds to 0), `claimableAmount` returns the full
    ///         unclaimed balance via the dust-escape branch.
    function testFuzz_DustEscape_ReturnsFullUnclaimed(
        uint256 totalAccrued
    ) public {
        // Single-slot collector: alice receives the full totalAccrued.
        totalAccrued = bound(totalAccrued, 1, 3);

        _receiveFees(c1Slot, launchToken, totalAccrued);

        // Pre-claim: unclaimed == totalAccrued.
        assertEq(
            c1Slot.claimableAmount(alice, address(launchToken)),
            totalAccrued,
            "dust escape returns full unclaimed pre-claim"
        );

        // After claim: unclaimed == 0.
        vm.prank(alice);
        c1Slot.claim(address(launchToken), 0, type(uint256).max);
        assertEq(c1Slot.claimableAmount(alice, address(launchToken)), 0, "post-drain claimable is zero");
    }

    /// @notice Across multiple claim windows (each separated by 1 day + 1 second), totalClaimed
    ///         never exceeds totalAccrued, and each per-window draw is bounded by the cap.
    function testFuzz_RateLimit_RespectedAcrossWindows(
        uint256 totalAccrued,
        uint8 numClaims
    ) public {
        // Skip the dust-escape regime so the cap is meaningful.
        totalAccrued = bound(totalAccrued, 100, 1e30);
        numClaims = uint8(bound(numClaims, 1, 10));

        _receiveFees(c1Slot, launchToken, totalAccrued);
        uint256 cap = totalAccrued / 4;

        uint256 totalClaimed;
        for (uint256 i = 0; i < numClaims; i++) {
            uint256 claimable = c1Slot.claimableAmount(alice, address(launchToken));
            // Cap holds at the start of every window (claimedInCurrentPeriod == 0 after warp).
            assertLe(claimable, cap, "per-window claimable exceeds cap");

            if (claimable > 0) {
                vm.prank(alice);
                c1Slot.claim(address(launchToken), 0, type(uint256).max);
                totalClaimed += claimable;
            }
            // Advance to the next 24h window so the rate-limit accumulator resets.
            vm.warp(block.timestamp + 1 days + 1);
        }

        assertLe(totalClaimed, totalAccrued, "totalClaimed exceeds totalAccrued");
        (uint256 actualAccrued, uint256 actualClaimed,,) = c1Slot.claimStates(0, address(launchToken));
        assertEq(actualAccrued, totalAccrued, "totalAccrued unchanged");
        assertEq(actualClaimed, totalClaimed, "ghost matches contract claimed");
    }

    // ============ Slot rotation ============

    /// @notice After rotating any single slot to a fresh `newAddress`, the reverse map
    ///         (`slotOf`) remains a valid inverse for every populated slot, and the old
    ///         address is no longer marked as an integrator.
    function testFuzz_Rotate_ReverseMapInjective(
        address newAddress,
        uint8 slotToRotateSeed
    ) public {
        uint8 slotToRotate = uint8(bound(slotToRotateSeed, 0, 2));
        // Filter newAddress: not zero, not an existing integrator, not the collector.
        vm.assume(newAddress != address(0));
        vm.assume(newAddress != alice && newAddress != bob && newAddress != carol);
        vm.assume(newAddress != address(c3Slot));

        address oldAddr = c3Slot.integrators(slotToRotate);
        vm.prank(oldAddr);
        c3Slot.signalChangeAddress(newAddress);
        vm.warp(block.timestamp + c3Slot.ROTATION_DELAY());
        c3Slot.executeChangeAddress(slotToRotate, newAddress);

        // Reverse map injective: every slot resolves to its own address, and every address
        // resolves back to its slot.
        for (uint256 i = 0; i < 3; i++) {
            address slotAddr = c3Slot.integrators(i);
            assertEq(c3Slot.slotOf(slotAddr), i, "slotOf inverse mismatch");
            assertTrue(slotAddr != address(0), "no zero address post-rotation");
        }
        // Old address is no longer an integrator.
        assertFalse(c3Slot.isIntegrator(oldAddr), "old address still tagged as integrator");
        // New address IS the integrator at the rotated slot.
        assertEq(c3Slot.slotOf(newAddress), slotToRotate, "newAddress not at expected slot");
    }

    /// @notice Accrual survives rotation: fees received before the rotation are claimable by
    ///         the new address afterwards (slot-keyed accounting).
    function testFuzz_Rotate_AccrualSurvives(
        uint256 amount,
        address newAddress
    ) public {
        amount = bound(amount, 100, 1e30);
        vm.assume(newAddress != address(0));
        vm.assume(newAddress != alice && newAddress != bob && newAddress != carol);
        vm.assume(newAddress != address(c3Slot));
        // Avoid rotating to router/raiseToken so the swap on claim works as expected.
        vm.assume(newAddress != address(router));
        vm.assume(newAddress != address(raiseToken));

        _receiveFees(c3Slot, launchToken, amount);
        uint256 aliceShare = (amount * 5000) / 10_000; // slot 0 = 50% in the 3-slot config

        vm.prank(alice);
        c3Slot.signalChangeAddress(newAddress);
        vm.warp(block.timestamp + c3Slot.ROTATION_DELAY());
        c3Slot.executeChangeAddress(0, newAddress);

        // Accrual is slot-keyed → unchanged across rotation.
        (uint256 acc,,,) = c3Slot.claimStates(0, address(launchToken));
        assertEq(acc, aliceShare, "slot 0 accrual lost on rotation");

        uint256 claimable = c3Slot.claimableAmount(newAddress, address(launchToken));
        assertGt(claimable, 0, "newAddress should have something to claim");

        vm.prank(newAddress);
        c3Slot.claim(address(launchToken), 0, type(uint256).max);
        assertEq(raiseToken.balanceOf(newAddress), claimable, "newAddress receives raise tokens");
    }

    // ============ claimBatch isolation ============

    /// @notice Per-token rate-limit consumption is isolated: a token whose swap reverts inside
    ///         `claimBatch` (forced via minOut > router output) leaves its rate-limit state
    ///         untouched, while successful tokens have their cap consumed for the current
    ///         window. `failPattern` is a 5-bit bitmask over the 5 tokens.
    function testFuzz_ClaimBatch_PartialFailure_RateLimitOnlyConsumedForSuccessful(
        uint256 amount,
        uint8 failPattern
    ) public {
        amount = bound(amount, 100, 1e30);
        // Skip the trivial cases: at least one success and at least one failure (i.e. exclude
        // 0 and 31) gives the most informative coverage. We don't strictly require this — the
        // assertions below handle all-success / all-fail correctly too — but tightening keeps
        // each fuzz run focused on the partial-failure path.
        uint8 mask = uint8(failPattern & 0x1F); // 5-bit mask

        // Receive fees on each of the 5 launch tokens for the 1-slot collector.
        for (uint256 i = 0; i < 5; i++) {
            _receiveFees(c1Slot, launchTokens[i], amount);
        }

        address[] memory tokenAddrs = new address[](5);
        uint256[] memory mins = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            tokenAddrs[i] = address(launchTokens[i]);
            bool fails = (mask & (1 << i)) != 0;
            // Demand impossible minOut → router reverts with SLIPPAGE → catch in claimBatch.
            mins[i] = fails ? type(uint256).max : 0;
        }

        vm.prank(alice);
        c1Slot.claimBatch(tokenAddrs, mins, type(uint256).max);

        uint256 expectedClaimable = amount / 4; // 25% cap (amount >= 100, so cap > 0)
        for (uint256 i = 0; i < 5; i++) {
            bool fails = (mask & (1 << i)) != 0;
            uint256 claimable = c1Slot.claimableAmount(alice, address(launchTokens[i]));
            (, uint256 totalClaimed,,) = c1Slot.claimStates(0, address(launchTokens[i]));
            if (fails) {
                assertEq(claimable, expectedClaimable, "failed token: rate limit must NOT be consumed");
                assertEq(totalClaimed, 0, "failed token: totalClaimed must be 0");
            } else {
                assertEq(claimable, 0, "successful token: rate-limit window should be drained");
                assertEq(totalClaimed, expectedClaimable, "successful token: totalClaimed = cap");
            }
        }
    }
}

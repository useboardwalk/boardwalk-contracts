// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VestingStream} from "src/core/VestingStream.sol";
import {IVestingStream} from "src/interfaces/IVestingStream.sol";
import {Timelocked} from "src/base/Timelocked.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @dev Simple ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @title VestingStreamTest
/// @notice Comprehensive unit + fuzz tests for VestingStream (EIP-1167 clone pattern)
contract VestingStreamTest is Test {
    // ============ Constants ============

    uint256 internal constant CLIFF_DURATION = 7 days;
    uint256 internal constant VESTING_DURATION = 3 * 365 days;
    uint256 internal constant TIMELOCK_DELAY = 7 days;
    uint256 internal constant TIMELOCK_EXPIRY = 7 days;

    // ============ State ============

    VestingStream internal template;
    VestingStream internal vestingStream;
    MockERC20 internal token;

    address internal presaleManager;
    address internal issuerAddr;
    address internal recipient1;
    address internal recipient2;
    address internal recipient3;
    address internal alice;
    address internal bob;

    uint256 internal liquiditySeedTime;

    // ============ Events (re-declared for vm.expectEmit) ============

    event VestingInitialized(uint256 indexed cliffEnd_, uint256 indexed vestingEnd_, uint256 indexed allocationCount_);
    event Claimed(uint256 indexed allocationId, address indexed recipient, uint256 amount);

    // ============ Setup ============

    function setUp() public {
        presaleManager = makeAddr("presaleManager");
        issuerAddr = makeAddr("issuer");
        recipient1 = makeAddr("recipient1");
        recipient2 = makeAddr("recipient2");
        recipient3 = makeAddr("recipient3");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.label(presaleManager, "presaleManager");
        vm.label(issuerAddr, "issuer");
        vm.label(recipient1, "recipient1");
        vm.label(recipient2, "recipient2");
        vm.label(recipient3, "recipient3");
        vm.label(alice, "alice");
        vm.label(bob, "bob");

        token = new MockERC20("TestToken", "TT");

        template = new VestingStream();
        liquiditySeedTime = block.timestamp;
    }

    // ============ Initialization ============

    function test_Initialize_SetsAllState() public {
        vestingStream = _deployAndInitialize(1, 1000e18);

        assertEq(address(vestingStream.token()), address(token), "token mismatch");
        assertEq(vestingStream.allocationCount(), 1, "allocationCount mismatch");
        assertEq(vestingStream.cliffEnd(), liquiditySeedTime + CLIFF_DURATION, "cliffEnd mismatch");
        assertEq(
            vestingStream.vestingEnd(), liquiditySeedTime + CLIFF_DURATION + VESTING_DURATION, "vestingEnd mismatch"
        );

        (address rec, uint256 total, uint256 claimed) = vestingStream.allocations(0);
        assertEq(rec, recipient1, "recipient mismatch");
        assertEq(total, 1000e18, "totalAmount mismatch");
        assertEq(claimed, 0, "claimed should be 0");
    }

    function test_Initialize_MultipleAllocations() public {
        address[] memory recipients = new address[](3);
        recipients[0] = recipient1;
        recipients[1] = recipient2;
        recipients[2] = recipient3;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000e18;
        amounts[1] = 2000e18;
        amounts[2] = 3000e18;

        vestingStream = _deployUninitialized();
        vm.prank(presaleManager);
        vestingStream.initialize(address(token), liquiditySeedTime, recipients, amounts);

        assertEq(vestingStream.allocationCount(), 3, "allocationCount should be 3");

        (address rec1, uint256 total1,) = vestingStream.allocations(0);
        assertEq(rec1, recipient1, "recipient1 mismatch");
        assertEq(total1, 1000e18, "amount1 mismatch");

        (address rec2, uint256 total2,) = vestingStream.allocations(1);
        assertEq(rec2, recipient2, "recipient2 mismatch");
        assertEq(total2, 2000e18, "amount2 mismatch");

        (address rec3, uint256 total3,) = vestingStream.allocations(2);
        assertEq(rec3, recipient3, "recipient3 mismatch");
        assertEq(total3, 3000e18, "amount3 mismatch");
    }

    function test_Initialize_EmitsInitializedEvent() public {
        vestingStream = _deployUninitialized();

        uint256 expectedCliffEnd = liquiditySeedTime + CLIFF_DURATION;
        uint256 expectedVestingEnd = liquiditySeedTime + CLIFF_DURATION + VESTING_DURATION;
        uint256 expectedAllocationCount = 1;

        vm.recordLogs();
        vm.prank(presaleManager);
        vestingStream.initialize(address(token), liquiditySeedTime, _toArray(recipient1), _toArray(1000e18));

        // Verify event was emitted by checking logs
        assertGt(vm.getRecordedLogs().length, 0, "should emit at least one event");

        // Verify state matches expected event values
        assertEq(vestingStream.cliffEnd(), expectedCliffEnd, "cliffEnd should match event");
        assertEq(vestingStream.vestingEnd(), expectedVestingEnd, "vestingEnd should match event");
        assertEq(vestingStream.allocationCount(), expectedAllocationCount, "allocationCount should match event");
    }

    function test_RevertWhen_InitializeTwice() public {
        vestingStream = _deployAndInitialize(1, 1000e18);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vm.prank(presaleManager);
        vestingStream.initialize(address(token), liquiditySeedTime, _toArray(recipient1), _toArray(1000e18));
    }

    function test_RevertWhen_InitializeWithZeroTokenAddress() public {
        vestingStream = _deployUninitialized();

        vm.expectRevert(VestingStream.ZeroAddress.selector);
        vm.prank(presaleManager);
        vestingStream.initialize(address(0), liquiditySeedTime, _toArray(recipient1), _toArray(1000e18));
    }

    function test_RevertWhen_InitializeWithZeroRecipientAddress() public {
        vestingStream = _deployUninitialized();

        address[] memory recipients = new address[](1);
        recipients[0] = address(0);

        vm.expectRevert(VestingStream.ZeroAddress.selector);
        vm.prank(presaleManager);
        vestingStream.initialize(address(token), liquiditySeedTime, recipients, _toArray(1000e18));
    }

    function test_RevertWhen_InitializeWithRecipientsAmountsLengthMismatch() public {
        vestingStream = _deployUninitialized();

        address[] memory recipients = new address[](2);
        recipients[0] = recipient1;
        recipients[1] = recipient2;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000e18;

        vm.expectRevert(VestingStream.ArrayLengthMismatch.selector);
        vm.prank(presaleManager);
        vestingStream.initialize(address(token), liquiditySeedTime, recipients, amounts);
    }

    function test_TemplateCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        template.initialize(address(token), liquiditySeedTime, _toArray(recipient1), _toArray(1000e18));
    }

    // ============ Claim ============

    function test_Claim_HappyPath_SingleAllocation() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        // Warp past cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 1);

        uint256 expectedClaimable = _calculateVested(totalAmount, 1);
        uint256 balanceBefore = token.balanceOf(recipient1);

        vm.expectEmit(true, true, false, true);
        emit Claimed(0, recipient1, expectedClaimable);

        vm.prank(recipient1);
        vestingStream.claim(0);

        assertEq(token.balanceOf(recipient1), balanceBefore + expectedClaimable, "recipient balance mismatch");
        (,, uint256 claimed) = vestingStream.allocations(0);
        assertEq(claimed, expectedClaimable, "claimed amount mismatch");
    }

    function test_Claim_HappyPath_MultiplePartialClaims() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        // First claim: 1 day after cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 1 days);
        uint256 claim1 = _calculateVested(totalAmount, 1 days);

        vm.prank(recipient1);
        vestingStream.claim(0);

        assertEq(token.balanceOf(recipient1), claim1, "first claim balance mismatch");
        (,, uint256 claimed1) = vestingStream.allocations(0);
        assertEq(claimed1, claim1, "first claimed amount mismatch");

        // Second claim: 1 year after cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 365 days);
        uint256 totalVested = _calculateVested(totalAmount, 365 days);

        vm.prank(recipient1);
        vestingStream.claim(0);

        assertEq(token.balanceOf(recipient1), totalVested, "second claim balance mismatch");
        (,, uint256 claimed2) = vestingStream.allocations(0);
        assertEq(claimed2, totalVested, "second claimed amount mismatch");
    }

    function test_Claim_AtExactCliffBoundary() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        // Warp to exact cliff end
        vm.warp(liquiditySeedTime + CLIFF_DURATION);

        // At exact cliff boundary, claimable is 0, so claim should revert with NothingToClaim
        vm.expectRevert(VestingStream.NothingToClaim.selector);
        vm.prank(recipient1);
        vestingStream.claim(0);
    }

    function test_Claim_AfterFullVesting() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        // Warp past vesting end
        vm.warp(liquiditySeedTime + CLIFF_DURATION + VESTING_DURATION + 1 days);

        vm.prank(recipient1);
        vestingStream.claim(0);

        assertEq(token.balanceOf(recipient1), totalAmount, "should claim full amount");
        (,, uint256 claimed) = vestingStream.allocations(0);
        assertEq(claimed, totalAmount, "claimed should equal totalAmount");
    }

    function test_Claim_MultipleAllocations() public {
        address[] memory recipients = new address[](2);
        recipients[0] = recipient1;
        recipients[1] = recipient2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000e18;
        amounts[1] = 2000e18;

        vestingStream = _deployUninitialized();
        vm.prank(presaleManager);
        vestingStream.initialize(address(token), liquiditySeedTime, recipients, amounts);

        _fundVestingStream(3000e18);

        // Warp past cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 365 days);

        uint256 vested1 = _calculateVested(1000e18, 365 days);
        uint256 vested2 = _calculateVested(2000e18, 365 days);

        vm.prank(recipient1);
        vestingStream.claim(0);

        vm.prank(recipient2);
        vestingStream.claim(1);

        assertEq(token.balanceOf(recipient1), vested1, "recipient1 balance mismatch");
        assertEq(token.balanceOf(recipient2), vested2, "recipient2 balance mismatch");
    }

    function test_RevertWhen_ClaimBeforeCliff() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        // Warp to 1 second before cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                VestingStream.CliffNotEnded.selector, liquiditySeedTime + CLIFF_DURATION, block.timestamp
            )
        );
        vm.prank(recipient1);
        vestingStream.claim(0);
    }

    function test_RevertWhen_ClaimByNonRecipient() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        vm.warp(liquiditySeedTime + CLIFF_DURATION + 1);

        vm.expectRevert(VestingStream.NotRecipient.selector);
        vm.prank(alice);
        vestingStream.claim(0);
    }

    function test_RevertWhen_ClaimInvalidAllocationId() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        _fundVestingStream(1000e18);

        vm.warp(liquiditySeedTime + CLIFF_DURATION + 1);

        vm.expectRevert(abi.encodeWithSelector(VestingStream.InvalidAllocationId.selector, 1));
        vm.prank(recipient1);
        vestingStream.claim(1);
    }

    function test_RevertWhen_ClaimNothingToClaim() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        vm.warp(liquiditySeedTime + CLIFF_DURATION + 1);

        // Claim once
        vm.prank(recipient1);
        vestingStream.claim(0);

        // Try to claim again immediately (no new vesting)
        vm.expectRevert(VestingStream.NothingToClaim.selector);
        vm.prank(recipient1);
        vestingStream.claim(0);
    }

    // ============ Claimable ============

    function test_Claimable_ReturnsZeroBeforeCliff() public {
        vestingStream = _deployAndInitialize(1, 1000e18);

        // Before cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION - 1);
        assertEq(vestingStream.claimable(0), 0, "should return 0 before cliff");
    }

    function test_Claimable_ReturnsZeroAtExactCliff() public {
        vestingStream = _deployAndInitialize(1, 1000e18);

        // At exact cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION);
        assertEq(vestingStream.claimable(0), 0, "should return 0 at exact cliff");
    }

    function test_Claimable_LinearVestingAfterCliff() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);

        // 1 day after cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 1 days);
        uint256 expected = _calculateVested(totalAmount, 1 days);
        assertEq(vestingStream.claimable(0), expected, "claimable mismatch after 1 day");

        // 1 year after cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 365 days);
        expected = _calculateVested(totalAmount, 365 days);
        assertEq(vestingStream.claimable(0), expected, "claimable mismatch after 1 year");

        // 2 years after cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 730 days);
        expected = _calculateVested(totalAmount, 730 days);
        assertEq(vestingStream.claimable(0), expected, "claimable mismatch after 2 years");
    }

    function test_Claimable_CapsAtTotalAmount() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);

        // After full vesting period
        vm.warp(liquiditySeedTime + CLIFF_DURATION + VESTING_DURATION + 1 days);
        assertEq(vestingStream.claimable(0), totalAmount, "should cap at totalAmount");
    }

    function test_Claimable_AccountsForPreviousClaims() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        // First claim
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 365 days);
        uint256 firstClaim = _calculateVested(totalAmount, 365 days);
        vm.prank(recipient1);
        vestingStream.claim(0);

        // Check claimable after first claim
        uint256 claimableAfter = vestingStream.claimable(0);
        assertEq(claimableAfter, 0, "should be 0 immediately after claiming");

        // Warp forward and check again
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 730 days);
        uint256 totalVested = _calculateVested(totalAmount, 730 days);
        uint256 expectedClaimable = totalVested - firstClaim;
        assertEq(vestingStream.claimable(0), expectedClaimable, "should account for previous claims");
    }

    function test_Claimable_ReturnsZeroForInvalidAllocationId() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        assertEq(vestingStream.claimable(1), 0, "should return 0 for invalid id");
        assertEq(vestingStream.claimable(999), 0, "should return 0 for invalid id");
    }

    // ============ TotalVested ============

    function test_TotalVested_ReturnsZeroBeforeCliff() public {
        vestingStream = _deployAndInitialize(1, 1000e18);

        vm.warp(liquiditySeedTime + CLIFF_DURATION - 1);
        assertEq(vestingStream.totalVested(0), 0, "should return 0 before cliff");
    }

    function test_TotalVested_ReturnsZeroAtExactCliff() public {
        vestingStream = _deployAndInitialize(1, 1000e18);

        vm.warp(liquiditySeedTime + CLIFF_DURATION);
        assertEq(vestingStream.totalVested(0), 0, "should return 0 at exact cliff");
    }

    function test_TotalVested_LinearVestingAfterCliff() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);

        // 1 day after cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 1 days);
        uint256 expected = _calculateVested(totalAmount, 1 days);
        assertEq(vestingStream.totalVested(0), expected, "totalVested mismatch after 1 day");

        // 1 year after cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 365 days);
        expected = _calculateVested(totalAmount, 365 days);
        assertEq(vestingStream.totalVested(0), expected, "totalVested mismatch after 1 year");
    }

    function test_TotalVested_CapsAtTotalAmount() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);

        // After full vesting period
        vm.warp(liquiditySeedTime + CLIFF_DURATION + VESTING_DURATION + 1 days);
        assertEq(vestingStream.totalVested(0), totalAmount, "should cap at totalAmount");
    }

    function test_TotalVested_DoesNotAccountForClaims() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        // Claim some tokens
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 365 days);
        vm.prank(recipient1);
        vestingStream.claim(0);

        // totalVested should still reflect the full vested amount, not reduced by claims
        uint256 totalVested = vestingStream.totalVested(0);
        uint256 expected = _calculateVested(totalAmount, 365 days);
        assertEq(totalVested, expected, "totalVested should not account for claims");
    }

    function test_TotalVested_ReturnsZeroForInvalidAllocationId() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        assertEq(vestingStream.totalVested(1), 0, "should return 0 for invalid id");
    }

    // ============ Fuzz Tests ============

    function testFuzz_Claimable_LinearVesting(
        uint256 timeOffset,
        uint256 totalAmount
    ) public {
        // Bound inputs to valid ranges
        totalAmount = bound(totalAmount, 1e18, 1_000_000e18);
        timeOffset = bound(timeOffset, 0, VESTING_DURATION);

        vestingStream = _deployAndInitialize(1, totalAmount);

        vm.warp(liquiditySeedTime + CLIFF_DURATION + timeOffset);

        uint256 expected = _calculateVested(totalAmount, timeOffset);
        uint256 actual = vestingStream.claimable(0);

        // Allow for rounding differences (within 1 wei)
        // Handle case where expected is 0 to avoid underflow
        if (expected == 0) {
            assertEq(actual, 0, "claimable should be 0 when expected is 0");
        } else {
            assertGe(actual, expected - 1, "claimable should be at least expected - 1");
            assertLe(actual, expected + 1, "claimable should be at most expected + 1");
        }
    }

    function testFuzz_Claim_MultiplePartialClaims(
        uint256 claim1Time,
        uint256 claim2Time,
        uint256 totalAmount
    ) public {
        // Bound inputs
        totalAmount = bound(totalAmount, 100e18, 1_000_000e18);
        claim1Time = bound(claim1Time, 1 days, VESTING_DURATION / 2);
        claim2Time = bound(claim2Time, claim1Time + 1 days, VESTING_DURATION);

        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        // First claim
        vm.warp(liquiditySeedTime + CLIFF_DURATION + claim1Time);
        vm.prank(recipient1);
        vestingStream.claim(0);

        // Second claim
        vm.warp(liquiditySeedTime + CLIFF_DURATION + claim2Time);
        vm.prank(recipient1);
        vestingStream.claim(0);

        // Verify total claimed equals total vested
        uint256 totalVested = _calculateVested(totalAmount, claim2Time);
        (,, uint256 claimed) = vestingStream.allocations(0);
        assertGe(claimed, totalVested - 1, "total claimed should match total vested");
        assertLe(claimed, totalVested + 1, "total claimed should match total vested");
    }

    function testFuzz_TotalVested_CapsAtTotalAmount(
        uint256 timeOffset,
        uint256 totalAmount
    ) public {
        totalAmount = bound(totalAmount, 1e18, 1_000_000e18);
        // Test beyond vesting duration
        timeOffset = bound(timeOffset, VESTING_DURATION, VESTING_DURATION * 2);

        vestingStream = _deployAndInitialize(1, totalAmount);

        vm.warp(liquiditySeedTime + CLIFF_DURATION + timeOffset);

        uint256 totalVested = vestingStream.totalVested(0);
        assertEq(totalVested, totalAmount, "totalVested should cap at totalAmount");
    }

    function testFuzz_Claimable_AfterClaimIsZeroUntilMoreVests(
        uint256 claimTime,
        uint256 checkTime,
        uint256 totalAmount
    ) public {
        totalAmount = bound(totalAmount, 100e18, 1_000_000e18);
        claimTime = bound(claimTime, 1 days, VESTING_DURATION - 1 days);
        checkTime = bound(checkTime, claimTime, claimTime + 1 hours);

        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        // Claim at claimTime
        vm.warp(liquiditySeedTime + CLIFF_DURATION + claimTime);
        vm.prank(recipient1);
        vestingStream.claim(0);

        // Check claimable at checkTime (should be 0 if no new vesting)
        vm.warp(liquiditySeedTime + CLIFF_DURATION + checkTime);
        uint256 claimable = vestingStream.claimable(0);

        if (checkTime == claimTime) {
            assertEq(claimable, 0, "claimable should be 0 immediately after claiming");
        } else {
            // Should only be claimable if more time has passed
            uint256 expectedVested = _calculateVested(totalAmount, checkTime);
            uint256 claimedAtClaimTime = _calculateVested(totalAmount, claimTime);
            uint256 expectedClaimable = expectedVested - claimedAtClaimTime;
            assertGe(claimable, expectedClaimable - 1, "claimable should match expected");
            assertLe(claimable, expectedClaimable + 1, "claimable should match expected");
        }
    }

    // ============ Edge Cases ============

    function test_Claim_ExactVestingEnd() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        // Warp to exact vesting end
        vm.warp(liquiditySeedTime + CLIFF_DURATION + VESTING_DURATION);

        vm.prank(recipient1);
        vestingStream.claim(0);

        assertEq(token.balanceOf(recipient1), totalAmount, "should claim full amount at vesting end");
    }

    function test_Claim_MaxTimeAfterVestingEnd() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        // Warp 10 years after vesting end
        vm.warp(liquiditySeedTime + CLIFF_DURATION + VESTING_DURATION + 10 * 365 days);

        vm.prank(recipient1);
        vestingStream.claim(0);

        assertEq(token.balanceOf(recipient1), totalAmount, "should still claim full amount");
        (,, uint256 claimed) = vestingStream.allocations(0);
        assertEq(claimed, totalAmount, "claimed should equal totalAmount");
    }

    function test_Claim_OneWeiAmount() public {
        uint256 totalAmount = 1;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);

        vm.warp(liquiditySeedTime + CLIFF_DURATION + VESTING_DURATION);

        vm.prank(recipient1);
        vestingStream.claim(0);

        assertEq(token.balanceOf(recipient1), totalAmount, "should claim 1 wei");
    }

    function test_Claimable_PrecisionAtSmallAmounts() public {
        uint256 totalAmount = 1000; // Small amount in wei
        vestingStream = _deployAndInitialize(1, totalAmount);

        // 1 second after cliff
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 1);
        uint256 claimable = vestingStream.claimable(0);

        // Should be very small but non-zero (or zero due to rounding)
        assertLe(claimable, totalAmount, "claimable should not exceed totalAmount");
    }

    // ============ Timelocked Recipient Changes ============

    function test_SignalChangeRecipient_HappyPath() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        address newRecipient = makeAddr("newRecipient");

        _signalRecipientChange(0, newRecipient);

        bytes32 action = _recipientAction(0);
        (bool isPending, uint256 executeTime,) = vestingStream.getPendingChange(action);
        assertTrue(isPending, "change should be pending");
        assertEq(executeTime, block.timestamp + TIMELOCK_DELAY, "executeTime mismatch");
    }

    function test_ExecuteChangeRecipient_HappyPath() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        _fundVestingStream(1000e18);
        address newRecipient = makeAddr("newRecipient");

        _signalRecipientChange(0, newRecipient);
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vestingStream.executeChangeRecipientAddress(0, newRecipient);

        (address rec,,) = vestingStream.allocations(0);
        assertEq(rec, newRecipient, "recipient should be updated");
    }

    function test_ExecuteChangeRecipient_EmitsEvent() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        address newRecipient = makeAddr("newRecipient");

        _signalRecipientChange(0, newRecipient);
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectEmit(true, false, false, true);
        emit VestingStream.RecipientAddressChanged(0, recipient1, newRecipient);

        vestingStream.executeChangeRecipientAddress(0, newRecipient);
    }

    function test_CancelChangeRecipient_HappyPath() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        address newRecipient = makeAddr("newRecipient");

        _signalRecipientChange(0, newRecipient);

        bytes32 action = _recipientAction(0);
        vm.prank(issuerAddr);
        vestingStream.cancelAction(action);

        (bool isPending,,) = vestingStream.getPendingChange(action);
        assertFalse(isPending, "change should be canceled");

        (address rec,,) = vestingStream.allocations(0);
        assertEq(rec, recipient1, "recipient should be unchanged");
    }

    function test_RevertWhen_SignalAction_NotIssuer() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        address newRecipient = makeAddr("newRecipient");
        bytes32 action = _recipientAction(0);
        bytes32 dataHash = keccak256(abi.encode(newRecipient));

        vm.expectRevert(VestingStream.NotIssuer.selector);
        vm.prank(alice);
        vestingStream.signalAction(action, dataHash);

        vm.expectRevert(VestingStream.NotIssuer.selector);
        vm.prank(recipient1);
        vestingStream.signalAction(action, dataHash);
    }

    function test_RevertWhen_CancelAction_NotIssuer() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        address newRecipient = makeAddr("newRecipient");

        _signalRecipientChange(0, newRecipient);

        bytes32 action = _recipientAction(0);
        vm.expectRevert(VestingStream.NotIssuer.selector);
        vm.prank(alice);
        vestingStream.cancelAction(action);
    }

    function test_RevertWhen_ExecuteChangeRecipient_TooEarly() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        address newRecipient = makeAddr("newRecipient");

        _signalRecipientChange(0, newRecipient);

        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);

        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockTooEarly.selector, block.timestamp + 1));
        vestingStream.executeChangeRecipientAddress(0, newRecipient);
    }

    function test_RevertWhen_ExecuteChangeRecipient_Expired() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        address newRecipient = makeAddr("newRecipient");

        uint256 signalTime = block.timestamp;
        _signalRecipientChange(0, newRecipient);

        vm.warp(signalTime + TIMELOCK_DELAY + TIMELOCK_EXPIRY + 1);

        vm.expectRevert(
            abi.encodeWithSelector(Timelocked.TimelockExpired.selector, signalTime + TIMELOCK_DELAY + TIMELOCK_EXPIRY)
        );
        vestingStream.executeChangeRecipientAddress(0, newRecipient);
    }

    function test_RevertWhen_ExecuteChangeRecipient_ZeroAddress() public {
        vestingStream = _deployAndInitialize(1, 1000e18);

        _signalRecipientChange(0, address(0));

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(VestingStream.ZeroAddress.selector);
        vestingStream.executeChangeRecipientAddress(0, address(0));
    }

    function test_RevertWhen_ExecuteChangeRecipient_InvalidAllocationId() public {
        vestingStream = _deployAndInitialize(1, 1000e18);

        vm.expectRevert(abi.encodeWithSelector(VestingStream.InvalidAllocationId.selector, 5));
        vestingStream.executeChangeRecipientAddress(5, makeAddr("newRecipient"));
    }

    function test_RevertWhen_ExecuteChangeRecipient_NotSignaled() public {
        vestingStream = _deployAndInitialize(1, 1000e18);

        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        vestingStream.executeChangeRecipientAddress(0, makeAddr("newRecipient"));
    }

    function test_ChangeRecipient_AutoClaimsSendsVestedToOldRecipient() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);
        address newRecipient = makeAddr("newRecipient");

        // Warp past cliff so tokens vest (old recipient does NOT manually claim)
        vm.warp(liquiditySeedTime + CLIFF_DURATION + 365 days);
        uint256 vestedBeforeSignal = vestingStream.claimable(0);
        assertGt(vestedBeforeSignal, 0, "should have vested tokens");

        // Signal and wait 7 days (more tokens vest during delay)
        _signalRecipientChange(0, newRecipient);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        uint256 vestedAtExecute = vestingStream.claimable(0);
        assertGt(vestedAtExecute, vestedBeforeSignal, "more tokens vest during delay");

        // Execute -- auto-claim sends vested tokens to old recipient
        vestingStream.executeChangeRecipientAddress(0, newRecipient);

        assertEq(token.balanceOf(recipient1), vestedAtExecute, "old recipient should receive auto-claimed tokens");
        assertEq(vestingStream.claimable(0), 0, "claimable should be 0 right after execute");

        // Old recipient can no longer claim
        vm.expectRevert(VestingStream.NotRecipient.selector);
        vm.prank(recipient1);
        vestingStream.claim(0);

        // New recipient claims future vesting
        vm.warp(liquiditySeedTime + CLIFF_DURATION + VESTING_DURATION);
        uint256 remaining = vestingStream.claimable(0);
        assertGt(remaining, 0, "new recipient should have future claimable");
        vm.prank(newRecipient);
        vestingStream.claim(0);
        assertEq(token.balanceOf(newRecipient), remaining, "new recipient gets only future vesting");

        // Total distributed equals totalAmount
        assertEq(
            token.balanceOf(recipient1) + token.balanceOf(newRecipient), totalAmount, "total distributed should match"
        );
    }

    function test_ChangeRecipient_PreCliff_NoAutoTransfer() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);
        address newRecipient = makeAddr("newRecipient");

        // Signal immediately (before cliff)
        _signalRecipientChange(0, newRecipient);
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        assertEq(vestingStream.claimable(0), 0, "nothing claimable before cliff");

        vestingStream.executeChangeRecipientAddress(0, newRecipient);

        assertEq(token.balanceOf(recipient1), 0, "old recipient should receive nothing pre-cliff");
        (address rec,,) = vestingStream.allocations(0);
        assertEq(rec, newRecipient, "recipient should be updated");
    }

    function test_ChangeRecipient_VestingScheduleUnchanged() public {
        uint256 totalAmount = 1000e18;
        vestingStream = _deployAndInitialize(1, totalAmount);
        _fundVestingStream(totalAmount);
        address newRecipient = makeAddr("newRecipient");

        (, uint256 totalBefore,) = vestingStream.allocations(0);
        uint256 cliffEndBefore = vestingStream.cliffEnd();
        uint256 vestingEndBefore = vestingStream.vestingEnd();

        _signalRecipientChange(0, newRecipient);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vestingStream.executeChangeRecipientAddress(0, newRecipient);

        (, uint256 totalAfter,) = vestingStream.allocations(0);
        assertEq(totalAfter, totalBefore, "totalAmount should be unchanged");
        assertEq(vestingStream.cliffEnd(), cliffEndBefore, "cliffEnd should be unchanged");
        assertEq(vestingStream.vestingEnd(), vestingEndBefore, "vestingEnd should be unchanged");
    }

    function test_ExecuteChangeRecipient_IsPermissionless() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        address newRecipient = makeAddr("newRecipient");

        _signalRecipientChange(0, newRecipient);
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.prank(alice);
        vestingStream.executeChangeRecipientAddress(0, newRecipient);

        (address rec,,) = vestingStream.allocations(0);
        assertEq(rec, newRecipient, "anyone should be able to execute after delay");
    }

    function test_IssuerCanBurnRecipientChangeAction() public {
        vestingStream = _deployAndInitialize(1, 1000e18);
        bytes32 action = _recipientAction(0);

        vm.prank(issuerAddr);
        vestingStream.signalBurnAction(action);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vestingStream.executeBurnAction(action);

        assertTrue(vestingStream.isActionBurned(action), "action should be burned");

        // Signaling should now revert
        vm.expectRevert(abi.encodeWithSelector(Timelocked.ActionIsBurned.selector, action));
        vm.prank(issuerAddr);
        vestingStream.signalAction(action, keccak256(abi.encode(makeAddr("newRecipient"))));
    }

    function test_SetInitializer_SetsIssuer() public {
        address clone = Clones.clone(address(template));
        VestingStream vs = VestingStream(clone);
        address testIssuer = makeAddr("testIssuer");
        vs.setInitializer(presaleManager, testIssuer);
        assertEq(vs.issuer(), testIssuer, "issuer should be set");
    }

    // ============ Helpers ============

    /// @dev Compute the action key for a recipient change
    function _recipientAction(
        uint256 allocationId
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(vestingStream.ACTION_CHANGE_RECIPIENT(), allocationId));
    }

    /// @dev Signal a recipient change via the generic signalAction path
    function _signalRecipientChange(
        uint256 allocationId,
        address newAddress
    ) internal {
        bytes32 action = _recipientAction(allocationId);
        bytes32 dataHash = keccak256(abi.encode(newAddress));
        vm.prank(issuerAddr);
        vestingStream.signalAction(action, dataHash);
    }

    /// @dev Deploy an uninitialized VestingStream clone
    function _deployUninitialized() internal returns (VestingStream) {
        address clone = Clones.clone(address(template));
        VestingStream vs = VestingStream(clone);
        // Set presaleManager as authorized initializer and issuer (simulates factory)
        vs.setInitializer(presaleManager, issuerAddr);
        return vs;
    }

    /// @dev Deploy and initialize a VestingStream with a single allocation
    function _deployAndInitialize(
        uint256 numRecipients,
        uint256 amountPerRecipient
    ) internal returns (VestingStream) {
        address[] memory recipients = new address[](numRecipients);
        uint256[] memory amounts = new uint256[](numRecipients);

        for (uint256 i = 0; i < numRecipients; i++) {
            recipients[i] = i == 0 ? recipient1 : (i == 1 ? recipient2 : recipient3);
            amounts[i] = amountPerRecipient;
        }

        VestingStream vs = _deployUninitialized();
        vm.prank(presaleManager);
        vs.initialize(address(token), liquiditySeedTime, recipients, amounts);

        return vs;
    }

    /// @dev Fund the vesting stream contract with tokens
    function _fundVestingStream(
        uint256 amount
    ) internal {
        token.mint(address(vestingStream), amount);
    }

    /// @dev Calculate vested amount given total amount and time elapsed since cliff
    function _calculateVested(
        uint256 totalAmount,
        uint256 elapsed
    ) internal pure returns (uint256) {
        if (elapsed > VESTING_DURATION) {
            elapsed = VESTING_DURATION;
        }
        return totalAmount * elapsed / VESTING_DURATION;
    }

    /// @dev Helper to create single-element arrays
    function _toArray(
        address item
    ) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = item;
        return arr;
    }

    function _toArray(
        uint256 item
    ) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = item;
        return arr;
    }

    // ================================================================
    //  COVERAGE GAP TESTS
    // ================================================================

    function test_RevertWhen_SetInitializer_AlreadySet() public {
        VestingStream vs = _deployUninitialized();
        // setInitializer was already called in _deployUninitialized (sets presaleManager + issuer)
        vm.expectRevert(VestingStream.InitializerAlreadySet.selector);
        vs.setInitializer(makeAddr("attacker"), makeAddr("attacker2"));
    }

    function test_RevertWhen_SetInitializer_ZeroInitializerAddress() public {
        address clone = Clones.clone(address(template));
        VestingStream vs = VestingStream(clone);
        vm.expectRevert(VestingStream.ZeroAddress.selector);
        vs.setInitializer(address(0), issuerAddr);
    }

    function test_RevertWhen_SetInitializer_ZeroIssuerAddress() public {
        address clone = Clones.clone(address(template));
        VestingStream vs = VestingStream(clone);
        vm.expectRevert(VestingStream.ZeroAddress.selector);
        vs.setInitializer(presaleManager, address(0));
    }

    function test_RevertWhen_Initialize_NotInitializer() public {
        VestingStream vs = _deployUninitialized();
        // initializer is presaleManager, try to init from different address
        address[] memory r = new address[](1);
        r[0] = recipient1;
        uint256[] memory a = new uint256[](1);
        a[0] = 1000e18;

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(VestingStream.NotInitializer.selector);
        vs.initialize(address(token), liquiditySeedTime, r, a);
    }
}

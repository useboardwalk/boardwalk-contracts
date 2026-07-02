// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BoardwalkToken} from "src/core/BoardwalkToken.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @dev Minimal mock that records onTaxReceived calls for verification
contract MockFeeDistributor {
    uint256 public lastTaxAmount;
    uint256 public totalTaxReceived;
    uint256 public callCount;
    bool public observeBalances;
    BoardwalkToken public observedToken;
    address public observedFrom;
    address public observedTo;
    uint256 public callbackFromBalance;
    uint256 public callbackToBalance;
    uint256 public callbackFeeDistributorBalance;

    function setBalanceObservation(
        BoardwalkToken token_,
        address from_,
        address to_
    ) external {
        observeBalances = true;
        observedToken = token_;
        observedFrom = from_;
        observedTo = to_;
    }

    function onTaxReceived(
        uint256 amount
    ) external {
        lastTaxAmount = amount;
        totalTaxReceived += amount;
        callCount++;

        if (observeBalances) {
            callbackFromBalance = observedToken.balanceOf(observedFrom);
            callbackToBalance = observedToken.balanceOf(observedTo);
            callbackFeeDistributorBalance = observedToken.balanceOf(address(this));
        }
    }
}

/// @title BoardwalkTokenTest
/// @notice Unit and fuzz tests for BoardwalkToken (EIP-1167 clone).
contract BoardwalkTokenTest is Test {
    // ============ Constants ============

    uint256 internal constant TOTAL_SUPPLY = 10_000_000_000e18;
    uint256 internal constant ANTI_WHALE_TAX_BPS = 4000; // 40 %
    uint256 internal constant ANTI_WHALE_DURATION = 90 minutes; // 5 400 s
    uint256 internal constant BASE_TAX_BPS = 80; // 0.80 %
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ============ State ============

    BoardwalkToken internal template;
    BoardwalkToken internal token;
    MockFeeDistributor internal mockFeeDistributor;

    address internal presaleManager;
    address internal alice;
    address internal bob;
    address internal charlie;
    address internal exempt1;
    address internal exempt2;

    // ============ Events (re-declared for vm.expectEmit) ============

    event TokenInitialized(
        string name,
        string symbol,
        uint256 baseTaxBps,
        uint256 antiWhaleTaxBps,
        uint256 antiWhaleDuration,
        address feeDistributor,
        address presaleManager
    );
    event LiquiditySeedTimeSet(uint256 seedTime);
    event Transfer(address indexed from, address indexed to, uint256 value);

    // ============ Setup ============

    function setUp() public {
        presaleManager = makeAddr("presaleManager");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        exempt1 = makeAddr("exempt1");
        exempt2 = makeAddr("exempt2");

        template = new BoardwalkToken();
        mockFeeDistributor = new MockFeeDistributor();
        token = _deployInitializedToken();
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Initialization
    // ──────────────────────────────────────────────────────────────────────────

    function test_Initialize_SetsAllState() public view {
        assertEq(token.baseTaxBps(), BASE_TAX_BPS, "baseTaxBps mismatch");
        assertEq(token.feeDistributor(), address(mockFeeDistributor), "feeDistributor mismatch");
        assertEq(token.presaleManager(), presaleManager, "presaleManager mismatch");
        assertEq(token.liquiditySeedTime(), 0, "seedTime should be 0 before seeding");
        assertEq(token.totalSupply(), 0, "totalSupply should be 0 before any mint");
    }

    function test_Initialize_SetsExemptAddresses() public view {
        assertTrue(token.isExempt(exempt1), "exempt1 should be exempt");
        assertTrue(token.isExempt(exempt2), "exempt2 should be exempt");
        assertFalse(token.isExempt(alice), "alice should not be exempt");
        assertFalse(token.isExempt(bob), "bob should not be exempt");
    }

    function test_Initialize_SkipsZeroAddressInExemptList() public {
        BoardwalkToken t = _deployUninitializedToken();

        address[] memory exempts = new address[](3);
        exempts[0] = exempt1;
        exempts[1] = address(0);
        exempts[2] = exempt2;

        t.initialize(
            "Test",
            "T",
            BASE_TAX_BPS,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            presaleManager,
            exempts
        );

        assertTrue(t.isExempt(exempt1), "exempt1 should be exempt");
        assertTrue(t.isExempt(exempt2), "exempt2 should be exempt");
        // address(0) mapping defaults to false regardless, but the loop skips it
        assertFalse(t.isExempt(address(0)), "address(0) should not be marked exempt");
    }

    function test_Initialize_EmptyExemptList() public {
        BoardwalkToken t = _deployUninitializedToken();
        address[] memory exempts = new address[](0);
        t.initialize(
            "Test",
            "T",
            BASE_TAX_BPS,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            presaleManager,
            exempts
        );

        assertEq(t.baseTaxBps(), BASE_TAX_BPS, "should init with empty exempt list");
    }

    function test_Initialize_ZeroBaseTaxBps() public {
        BoardwalkToken t = _deployUninitializedToken();
        address[] memory exempts = new address[](0);
        t.initialize(
            "Test",
            "T",
            0,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            presaleManager,
            exempts
        );

        assertEq(t.baseTaxBps(), 0, "baseTaxBps should be 0");
    }

    function test_Initialize_MaxBaseTaxBps() public {
        BoardwalkToken t = _deployUninitializedToken();
        address[] memory exempts = new address[](0);
        t.initialize(
            "Test",
            "T",
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            presaleManager,
            exempts
        );

        assertEq(t.baseTaxBps(), ANTI_WHALE_TAX_BPS, "baseTaxBps should accept max (4000)");
    }

    function test_Initialize_EmitsInitializedEvent() public {
        BoardwalkToken t = _deployUninitializedToken();
        address[] memory exempts = new address[](0);

        vm.expectEmit(true, true, true, true, address(t));
        emit TokenInitialized(
            "MyToken",
            "MT",
            BASE_TAX_BPS,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            presaleManager
        );

        t.initialize(
            "MyToken",
            "MT",
            BASE_TAX_BPS,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            presaleManager,
            exempts
        );
    }

    function test_RevertWhen_InitializeTwice() public {
        address[] memory exempts = new address[](0);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        token.initialize(
            "Other",
            "OT",
            100,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            presaleManager,
            exempts
        );
    }

    function test_RevertWhen_Initialize_BaseTaxBpsExceedsMax() public {
        BoardwalkToken t = _deployUninitializedToken();
        address[] memory exempts = new address[](0);

        vm.expectRevert(BoardwalkToken.InvalidBaseTaxBps.selector);
        t.initialize(
            "Test",
            "T",
            ANTI_WHALE_TAX_BPS + 1,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            presaleManager,
            exempts
        );
    }

    function test_RevertWhen_Initialize_ZeroFeeDistributor() public {
        BoardwalkToken t = _deployUninitializedToken();
        address[] memory exempts = new address[](0);

        vm.expectRevert(BoardwalkToken.ZeroAddress.selector);
        t.initialize(
            "Test", "T", BASE_TAX_BPS, ANTI_WHALE_TAX_BPS, ANTI_WHALE_DURATION, address(0), presaleManager, exempts
        );
    }

    function test_RevertWhen_Initialize_ZeroPresaleManager() public {
        BoardwalkToken t = _deployUninitializedToken();
        address[] memory exempts = new address[](0);

        vm.expectRevert(BoardwalkToken.ZeroAddress.selector);
        t.initialize(
            "Test",
            "T",
            BASE_TAX_BPS,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            address(0),
            exempts
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Constructor — W-01 fix: template cannot be re-initialized
    // ──────────────────────────────────────────────────────────────────────────

    function test_Constructor_DisablesInitOnTemplate() public {
        address[] memory exempts = new address[](0);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        template.initialize(
            "Test",
            "T",
            BASE_TAX_BPS,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            presaleManager,
            exempts
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Metadata overrides
    // ──────────────────────────────────────────────────────────────────────────

    function test_Name_ReturnsInitializedValue() public view {
        assertEq(token.name(), "TestToken", "name should match init value");
    }

    function test_Symbol_ReturnsInitializedValue() public view {
        assertEq(token.symbol(), "TT", "symbol should match init value");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Mint
    // ──────────────────────────────────────────────────────────────────────────

    function test_Mint_ByPresaleManager() public {
        uint256 amount = 1_000e18;

        vm.prank(presaleManager);
        token.mint(alice, amount);

        assertEq(token.balanceOf(alice), amount, "alice balance mismatch");
        assertEq(token.totalSupply(), amount, "totalSupply mismatch");
    }

    function test_Mint_MultipleMints() public {
        uint256 first = TOTAL_SUPPLY / 4;
        uint256 second = TOTAL_SUPPLY / 4;
        uint256 third = TOTAL_SUPPLY / 2;

        vm.startPrank(presaleManager);
        token.mint(alice, first);
        token.mint(bob, second);
        token.mint(charlie, third);
        vm.stopPrank();

        assertEq(token.totalSupply(), TOTAL_SUPPLY, "totalSupply should equal sum of all mints");
        assertEq(token.balanceOf(alice), first, "alice balance mismatch after multi-mint");
        assertEq(token.balanceOf(bob), second, "bob balance mismatch after multi-mint");
        assertEq(token.balanceOf(charlie), third, "charlie balance mismatch after multi-mint");
    }

    function test_Mint_ExactlyTotalSupply() public {
        vm.prank(presaleManager);
        token.mint(alice, TOTAL_SUPPLY);

        assertEq(token.totalSupply(), TOTAL_SUPPLY, "totalSupply should equal TOTAL_SUPPLY");
        assertEq(token.balanceOf(alice), TOTAL_SUPPLY, "alice should hold full supply");
    }

    function test_RevertWhen_Mint_ByNonPresaleManager() public {
        vm.prank(alice);
        vm.expectRevert(BoardwalkToken.OnlyPresaleManager.selector);
        token.mint(alice, 1_000e18);
    }

    function test_RevertWhen_Mint_ExceedsTotalSupply() public {
        vm.prank(presaleManager);
        vm.expectRevert(BoardwalkToken.ExceedsTotalSupply.selector);
        token.mint(alice, TOTAL_SUPPLY + 1);
    }

    function test_RevertWhen_Mint_ExceedsTotalSupplyAfterPartial() public {
        vm.startPrank(presaleManager);
        token.mint(alice, TOTAL_SUPPLY - 100e18);

        vm.expectRevert(BoardwalkToken.ExceedsTotalSupply.selector);
        token.mint(bob, 101e18); // 1e18 over remaining capacity
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  setLiquiditySeedTime
    // ──────────────────────────────────────────────────────────────────────────

    function test_SetLiquiditySeedTime_ByPresaleManager() public {
        uint256 seedTime = block.timestamp;

        vm.prank(presaleManager);
        token.setLiquiditySeedTime(seedTime);

        assertEq(token.liquiditySeedTime(), seedTime, "seedTime mismatch");
    }

    function test_SetLiquiditySeedTime_EmitsEvent() public {
        uint256 seedTime = block.timestamp;

        vm.expectEmit(true, true, true, true, address(token));
        emit LiquiditySeedTimeSet(seedTime);

        vm.prank(presaleManager);
        token.setLiquiditySeedTime(seedTime);
    }

    function test_RevertWhen_SetLiquiditySeedTime_ByNonPresaleManager() public {
        vm.prank(alice);
        vm.expectRevert(BoardwalkToken.OnlyPresaleManager.selector);
        token.setLiquiditySeedTime(block.timestamp);
    }

    function test_RevertWhen_SetLiquiditySeedTime_AlreadySeeded() public {
        vm.startPrank(presaleManager);
        token.setLiquiditySeedTime(block.timestamp);

        vm.expectRevert(BoardwalkToken.AlreadySeeded.selector);
        token.setLiquiditySeedTime(block.timestamp + 100);
        vm.stopPrank();
    }

    function test_RevertWhen_SetLiquiditySeedTime_Zero() public {
        vm.prank(presaleManager);
        vm.expectRevert(BoardwalkToken.ZeroSeedTime.selector);
        token.setLiquiditySeedTime(0);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Tax — no-tax cases
    // ──────────────────────────────────────────────────────────────────────────

    function test_Transfer_NoTaxBeforeSeedTime() public {
        uint256 amount = 1_000e18;
        _mintTo(alice, amount);

        // liquiditySeedTime is 0 -> token not yet trading -> no tax
        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(bob), amount, "bob should receive full amount before seed");
        assertEq(token.balanceOf(address(mockFeeDistributor)), 0, "feeDistributor should have 0 before seed");
        assertEq(mockFeeDistributor.callCount(), 0, "no callback before seed");
    }

    function test_Transfer_ExemptSenderNoTax() public {
        uint256 amount = 1_000e18;
        _mintTo(exempt1, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION);

        vm.prank(exempt1);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(bob), amount, "exempt sender should not pay tax");
    }

    function test_Transfer_ExemptReceiverNoTax() public {
        uint256 amount = 1_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION);

        vm.prank(alice);
        token.transfer(exempt1, amount);

        assertEq(token.balanceOf(exempt1), amount, "exempt receiver should not be taxed");
    }

    function test_Transfer_BothExempt_NoTax() public {
        uint256 amount = 1_000e18;
        _mintTo(exempt1, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION);

        vm.prank(exempt1);
        token.transfer(exempt2, amount);

        assertEq(token.balanceOf(exempt2), amount, "both exempt should not be taxed");
        assertEq(mockFeeDistributor.callCount(), 0, "no callback when both are exempt");
    }

    function test_Transfer_MintHasNoTax() public {
        _seedLiquidity();
        vm.warp(token.liquiditySeedTime()); // t = 0 -> 40 % anti-whale active

        uint256 amount = 1_000e18;
        vm.prank(presaleManager);
        token.mint(alice, amount);

        // Mint = from == address(0), skips tax entirely
        assertEq(token.balanceOf(alice), amount, "mint should never be taxed");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Tax — anti-whale decay
    // ──────────────────────────────────────────────────────────────────────────

    function test_Transfer_AntiWhale_AtSeedTime_40Percent() public {
        uint256 amount = 10_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime()); // elapsed = 0

        vm.prank(alice);
        token.transfer(bob, amount);

        // 40 % tax at t = 0
        uint256 expectedTax = amount * ANTI_WHALE_TAX_BPS / BPS_DENOMINATOR;
        assertEq(token.balanceOf(bob), amount - expectedTax, "bob should receive 60 % at seed time");
        assertEq(
            token.balanceOf(address(mockFeeDistributor)), expectedTax, "feeDistributor should receive 40 % at seed time"
        );
    }

    function test_Transfer_AntiWhale_Midpoint() public {
        uint256 amount = 10_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION / 2); // 45 min

        // currentTax = 4000 - (4000 - 80) * 2700 / 5400 = 4000 - 1960 = 2040 bps
        uint256 halfDuration = ANTI_WHALE_DURATION / 2;
        uint256 expectedTaxBps =
            ANTI_WHALE_TAX_BPS - (ANTI_WHALE_TAX_BPS - BASE_TAX_BPS) * halfDuration / ANTI_WHALE_DURATION;
        uint256 expectedTax = amount * expectedTaxBps / BPS_DENOMINATOR;

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(bob), amount - expectedTax, "bob balance at midpoint mismatch");
        assertEq(token.balanceOf(address(mockFeeDistributor)), expectedTax, "feeDistributor at midpoint mismatch");
    }

    function test_Transfer_AntiWhale_OneSecondBeforeEnd() public {
        uint256 amount = 10_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        uint256 elapsed = ANTI_WHALE_DURATION - 1;
        vm.warp(token.liquiditySeedTime() + elapsed);

        // Still in linear decay: slightly above baseTaxBps due to integer truncation
        uint256 expectedTaxBps =
            ANTI_WHALE_TAX_BPS - (ANTI_WHALE_TAX_BPS - BASE_TAX_BPS) * elapsed / ANTI_WHALE_DURATION;
        uint256 expectedTax = amount * expectedTaxBps / BPS_DENOMINATOR;

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(bob), amount - expectedTax, "bob balance 1s before end mismatch");
        assertGt(expectedTaxBps, BASE_TAX_BPS, "tax 1s before end should be > baseTaxBps");
    }

    function test_Transfer_AntiWhale_ExactlyAtEnd() public {
        uint256 amount = 10_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION); // exactly 90 min

        // elapsed >= ANTI_WHALE_DURATION -> flat baseTaxBps
        uint256 expectedTax = amount * BASE_TAX_BPS / BPS_DENOMINATOR;

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(bob), amount - expectedTax, "should use flat baseTaxBps at exactly 90 min");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Tax — flat base tax (after anti-whale window)
    // ──────────────────────────────────────────────────────────────────────────

    function test_Transfer_FlatBaseTax_AfterAntiWhale() public {
        uint256 amount = 10_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION + 1);

        uint256 expectedTax = amount * BASE_TAX_BPS / BPS_DENOMINATOR;

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(bob), amount - expectedTax, "bob should receive amount minus base tax");
        assertEq(token.balanceOf(address(mockFeeDistributor)), expectedTax, "feeDistributor should receive base tax");
    }

    function test_Transfer_FlatBaseTax_LongAfterSeed() public {
        uint256 amount = 5_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + 365 days);

        uint256 expectedTax = amount * BASE_TAX_BPS / BPS_DENOMINATOR;

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(bob), amount - expectedTax, "flat base tax should still apply 1 year later");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Tax — transfer flow (feeDistributor + callback)
    // ──────────────────────────────────────────────────────────────────────────

    function test_Transfer_TaxSentToFeeDistributor() public {
        uint256 amount = 10_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION);

        uint256 expectedTax = amount * BASE_TAX_BPS / BPS_DENOMINATOR;

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(address(mockFeeDistributor)), expectedTax, "feeDistributor should hold the tax tokens");
    }

    function test_Transfer_OnTaxReceivedCallbackTriggered() public {
        uint256 amount = 10_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION);

        uint256 expectedTax = amount * BASE_TAX_BPS / BPS_DENOMINATOR;

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(mockFeeDistributor.callCount(), 1, "onTaxReceived should be called once");
        assertEq(mockFeeDistributor.lastTaxAmount(), expectedTax, "callback amount should match tax");
    }

    function test_Transfer_CallbackObservesPostTransferBalances() public {
        uint256 amount = 10_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION);

        uint256 expectedTax = amount * BASE_TAX_BPS / BPS_DENOMINATOR;
        mockFeeDistributor.setBalanceObservation(token, alice, bob);

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(mockFeeDistributor.callbackFromBalance(), 0, "sender should be fully debited before callback");
        assertEq(
            mockFeeDistributor.callbackToBalance(), amount - expectedTax, "recipient should be credited before callback"
        );
        assertEq(
            mockFeeDistributor.callbackFeeDistributorBalance(),
            expectedTax,
            "feeDistributor should hold tax before callback"
        );
    }

    function test_Transfer_NoCallbackWhenNoTax() public {
        uint256 amount = 1_000e18;
        _mintTo(exempt1, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION);

        vm.prank(exempt1);
        token.transfer(bob, amount);

        assertEq(mockFeeDistributor.callCount(), 0, "no callback when sender is exempt (tax = 0)");
    }

    function test_Transfer_RecipientPlusTaxEqualsOriginalAmount() public {
        uint256 amount = 10_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION);

        vm.prank(alice);
        token.transfer(bob, amount);

        uint256 bobBalance = token.balanceOf(bob);
        uint256 feeBalance = token.balanceOf(address(mockFeeDistributor));

        assertEq(bobBalance + feeBalance, amount, "recipient + feeDistributor should equal original amount");
    }

    function test_TransferFrom_TaxApplied() public {
        uint256 amount = 10_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION);

        vm.prank(alice);
        token.approve(charlie, amount);

        uint256 expectedTax = amount * BASE_TAX_BPS / BPS_DENOMINATOR;

        vm.prank(charlie);
        token.transferFrom(alice, bob, amount);

        assertEq(token.balanceOf(bob), amount - expectedTax, "transferFrom should also deduct tax");
        assertEq(
            token.balanceOf(address(mockFeeDistributor)),
            expectedTax,
            "feeDistributor should receive tax from transferFrom"
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Tax — universal (wallet-to-wallet is taxed)
    // ──────────────────────────────────────────────────────────────────────────

    function test_Transfer_WalletToWallet_IsTaxed() public {
        uint256 amount = 5_000e18;
        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION);

        // First hop: alice -> bob
        vm.prank(alice);
        token.transfer(bob, amount);

        uint256 tax1 = amount * BASE_TAX_BPS / BPS_DENOMINATOR;
        assertEq(token.balanceOf(bob), amount - tax1, "first wallet-to-wallet hop should be taxed");

        // Second hop: bob -> charlie
        uint256 bobBalance = token.balanceOf(bob);
        vm.prank(bob);
        token.transfer(charlie, bobBalance);

        uint256 tax2 = bobBalance * BASE_TAX_BPS / BPS_DENOMINATOR;
        assertEq(token.balanceOf(charlie), bobBalance - tax2, "second wallet-to-wallet hop should be taxed");
    }

    function test_Transfer_MultipleTransfers_AccumulateTax() public {
        uint256 amount = 1_000e18;
        _mintTo(alice, amount * 3);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION);

        vm.startPrank(alice);
        token.transfer(bob, amount);
        token.transfer(bob, amount);
        token.transfer(bob, amount);
        vm.stopPrank();

        uint256 taxPerTransfer = amount * BASE_TAX_BPS / BPS_DENOMINATOR;

        assertEq(mockFeeDistributor.callCount(), 3, "callback should fire once per taxed transfer");
        assertEq(
            token.balanceOf(address(mockFeeDistributor)),
            taxPerTransfer * 3,
            "accumulated tax should equal 3x single-transfer tax"
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Tax — edge cases: zero baseTaxBps
    // ──────────────────────────────────────────────────────────────────────────

    function test_Transfer_ZeroBaseTaxBps_NoTaxAfterAntiWhale() public {
        (BoardwalkToken zeroTaxToken, MockFeeDistributor fd) = _deployTokenWithBaseTax(0);

        uint256 amount = 1_000e18;
        vm.prank(presaleManager);
        zeroTaxToken.mint(alice, amount);

        vm.prank(presaleManager);
        zeroTaxToken.setLiquiditySeedTime(block.timestamp);

        vm.warp(block.timestamp + ANTI_WHALE_DURATION); // past anti-whale

        vm.prank(alice);
        zeroTaxToken.transfer(bob, amount);

        assertEq(zeroTaxToken.balanceOf(bob), amount, "zero baseTax -> no tax after anti-whale window");
        assertEq(fd.callCount(), 0, "no callback when tax is 0");
    }

    function test_Transfer_ZeroBaseTaxBps_AntiWhaleStillApplies() public {
        (BoardwalkToken zeroTaxToken, MockFeeDistributor fd) = _deployTokenWithBaseTax(0);

        uint256 amount = 1_000e18;
        vm.prank(presaleManager);
        zeroTaxToken.mint(alice, amount);

        vm.prank(presaleManager);
        zeroTaxToken.setLiquiditySeedTime(block.timestamp);

        // At t = 0: currentTax = 4000 - (4000 - 0) * 0 / 5400 = 4000
        vm.prank(alice);
        zeroTaxToken.transfer(bob, amount);

        uint256 expectedTax = amount * ANTI_WHALE_TAX_BPS / BPS_DENOMINATOR;
        assertEq(
            zeroTaxToken.balanceOf(bob), amount - expectedTax, "anti-whale 40 % should apply even with baseTaxBps = 0"
        );
        assertEq(fd.callCount(), 1, "callback should fire during anti-whale");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Tax — edge cases: max baseTaxBps (4000 = same as anti-whale)
    // ──────────────────────────────────────────────────────────────────────────

    function test_Transfer_MaxBaseTaxBps_NoDecayDuringAntiWhale() public {
        (BoardwalkToken maxTaxToken, MockFeeDistributor fd) = _deployTokenWithBaseTax(ANTI_WHALE_TAX_BPS);

        uint256 amount = 1_000e18;
        vm.prank(presaleManager);
        maxTaxToken.mint(alice, amount);

        vm.prank(presaleManager);
        maxTaxToken.setLiquiditySeedTime(block.timestamp);

        // Midpoint: currentTax = 4000 - (4000 - 4000) * x / 5400 = 4000 (constant)
        vm.warp(block.timestamp + ANTI_WHALE_DURATION / 2);

        vm.prank(alice);
        maxTaxToken.transfer(bob, amount);

        uint256 expectedTax = amount * ANTI_WHALE_TAX_BPS / BPS_DENOMINATOR;
        assertEq(
            maxTaxToken.balanceOf(bob), amount - expectedTax, "max baseTax -> no decay, always 40 % during anti-whale"
        );
        assertEq(fd.totalTaxReceived(), expectedTax, "feeDistributor tax mismatch for max baseTax");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Tax — edge case: small amounts (dust / rounding)
    // ──────────────────────────────────────────────────────────────────────────

    function test_Transfer_SmallAmount_TaxRoundsToZero() public {
        _mintTo(alice, 100e18);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION);

        // Transfer 2 wei: tax = 2 * 80 / 10000 = 0 (integer truncation)
        vm.prank(alice);
        token.transfer(bob, 2);

        assertEq(token.balanceOf(bob), 2, "dust transfer should round tax to 0");
        assertEq(mockFeeDistributor.callCount(), 0, "no callback when tax rounds to 0");
    }

    function test_Transfer_SmallAmountWithTax() public {
        _mintTo(alice, 100e18);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime()); // 40 % anti-whale

        // Transfer 3 wei: tax = 3 * 4000 / 10000 = 1 (truncated)
        vm.prank(alice);
        token.transfer(bob, 3);

        assertEq(token.balanceOf(bob), 2, "3 wei transfer at 40 % tax -> 2 wei received");
        assertEq(token.balanceOf(address(mockFeeDistributor)), 1, "1 wei tax on 3 wei transfer");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Fuzz — mint
    // ──────────────────────────────────────────────────────────────────────────

    function testFuzz_Mint_UpToCap(
        uint256 amount
    ) public {
        amount = bound(amount, 1, TOTAL_SUPPLY);

        vm.prank(presaleManager);
        token.mint(alice, amount);

        assertEq(token.totalSupply(), amount, "totalSupply should match minted amount");
        assertEq(token.balanceOf(alice), amount, "alice balance should match minted amount");
        assertLe(token.totalSupply(), TOTAL_SUPPLY, "totalSupply must never exceed cap");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Fuzz — tax properties
    // ──────────────────────────────────────────────────────────────────────────

    function testFuzz_Transfer_TaxNeverExceeds40Percent(
        uint256 amount,
        uint256 elapsed
    ) public {
        amount = bound(amount, 1e18, TOTAL_SUPPLY / 2);
        elapsed = bound(elapsed, 0, ANTI_WHALE_DURATION * 10);

        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + elapsed);

        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        token.transfer(bob, amount);

        uint256 bobReceived = token.balanceOf(bob);
        uint256 taxCollected = token.balanceOf(address(mockFeeDistributor));

        // Invariant 1: tax <= 40 % of amount
        assertLe(taxCollected, amount * ANTI_WHALE_TAX_BPS / BPS_DENOMINATOR, "tax must never exceed 40 %");

        // Invariant 2: recipient + tax == original amount
        assertEq(bobReceived + taxCollected, amount, "recipient + tax should equal original amount");

        // Invariant 3: sender debited exactly `amount`
        assertEq(aliceBefore - token.balanceOf(alice), amount, "sender should be debited exactly amount");
    }

    function testFuzz_Transfer_BaseTaxAfterAntiWhale(
        uint256 amount,
        uint256 extraElapsed
    ) public {
        amount = bound(amount, 1e18, TOTAL_SUPPLY / 2);
        extraElapsed = bound(extraElapsed, 0, 365 days);

        _mintTo(alice, amount);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + ANTI_WHALE_DURATION + extraElapsed);

        vm.prank(alice);
        token.transfer(bob, amount);

        uint256 expectedTax = amount * BASE_TAX_BPS / BPS_DENOMINATOR;
        assertEq(token.balanceOf(bob), amount - expectedTax, "should always apply flat baseTaxBps after window");
    }

    function testFuzz_Transfer_AntiWhaleDecayMonotonic(
        uint256 t1,
        uint256 t2
    ) public {
        t1 = bound(t1, 0, ANTI_WHALE_DURATION - 1);
        t2 = bound(t2, t1, ANTI_WHALE_DURATION);

        uint256 amount = 10_000e18;
        uint256 seedTime = 10_000; // fixed reference
        vm.warp(seedTime); // Ensure block.timestamp >= seedTime for FutureSeedTime guard

        // ---- Token A: transfer at seedTime + t1 ----
        MockFeeDistributor fdA = new MockFeeDistributor();
        BoardwalkToken tokenA = _deployUninitializedToken();
        address[] memory noExempt = new address[](0);
        tokenA.initialize(
            "A", "A", BASE_TAX_BPS, ANTI_WHALE_TAX_BPS, ANTI_WHALE_DURATION, address(fdA), presaleManager, noExempt
        );

        vm.startPrank(presaleManager);
        tokenA.mint(alice, amount);
        tokenA.setLiquiditySeedTime(seedTime);
        vm.stopPrank();

        vm.warp(seedTime + t1);
        vm.prank(alice);
        tokenA.transfer(bob, amount);
        uint256 taxA = fdA.totalTaxReceived();

        // ---- Token B: transfer at seedTime + t2 ----
        MockFeeDistributor fdB = new MockFeeDistributor();
        BoardwalkToken tokenB = _deployUninitializedToken();
        tokenB.initialize(
            "B", "B", BASE_TAX_BPS, ANTI_WHALE_TAX_BPS, ANTI_WHALE_DURATION, address(fdB), presaleManager, noExempt
        );

        vm.startPrank(presaleManager);
        tokenB.mint(alice, amount);
        tokenB.setLiquiditySeedTime(seedTime);
        vm.stopPrank();

        vm.warp(seedTime + t2);
        vm.prank(alice);
        tokenB.transfer(bob, amount);
        uint256 taxB = fdB.totalTaxReceived();

        // Property: tax must decrease (or stay equal) as elapsed time grows
        assertGe(taxA, taxB, "tax should decrease monotonically over time");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Fuzz — initialization
    // ──────────────────────────────────────────────────────────────────────────

    function testFuzz_Initialize_ValidBaseTaxBps(
        uint256 bps
    ) public {
        bps = bound(bps, 0, ANTI_WHALE_TAX_BPS);

        BoardwalkToken t = _deployUninitializedToken();
        address[] memory exempts = new address[](0);
        t.initialize(
            "Test",
            "T",
            bps,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            presaleManager,
            exempts
        );

        assertEq(t.baseTaxBps(), bps, "baseTaxBps should be stored correctly for any valid value");
    }

    function testFuzz_Initialize_InvalidBaseTaxBps_Reverts(
        uint256 bps
    ) public {
        bps = bound(bps, ANTI_WHALE_TAX_BPS + 1, type(uint256).max - 1);

        BoardwalkToken t = _deployUninitializedToken();
        address[] memory exempts = new address[](0);

        // baseTaxBps > antiWhaleTaxBps reverts InvalidBaseTaxBps;
        // antiWhaleTaxBps > 10000 (BPS_DENOMINATOR) reverts InvalidAntiWhaleConfig.
        // Since we hold antiWhaleTaxBps == 4000, the bound on bps guarantees InvalidBaseTaxBps.
        vm.expectRevert(BoardwalkToken.InvalidBaseTaxBps.selector);
        t.initialize(
            "Test",
            "T",
            bps,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            presaleManager,
            exempts
        );
    }

    function testFuzz_Transfer_ZeroAmountNoTax(
        uint256 elapsed
    ) public {
        elapsed = bound(elapsed, 0, 365 days);

        _mintTo(alice, 1_000e18);
        _seedLiquidity();

        vm.warp(token.liquiditySeedTime() + elapsed);

        vm.prank(alice);
        token.transfer(bob, 0);

        assertEq(token.balanceOf(bob), 0, "zero-amount transfer should result in zero received");
        assertEq(mockFeeDistributor.callCount(), 0, "no callback on zero-amount transfer");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Deploy an uninitialized EIP-1167 clone of the template
    function _deployUninitializedToken() internal returns (BoardwalkToken) {
        address clone = Clones.clone(address(template));
        return BoardwalkToken(clone);
    }

    /// @dev Deploy and initialize the standard token used by most tests
    function _deployInitializedToken() internal returns (BoardwalkToken) {
        BoardwalkToken t = _deployUninitializedToken();

        address[] memory exempts = new address[](2);
        exempts[0] = exempt1;
        exempts[1] = exempt2;

        t.initialize(
            "TestToken",
            "TT",
            BASE_TAX_BPS,
            ANTI_WHALE_TAX_BPS,
            ANTI_WHALE_DURATION,
            address(mockFeeDistributor),
            presaleManager,
            exempts
        );
        return t;
    }

    /// @dev Deploy a token with a specific baseTaxBps (no exempt addresses)
    function _deployTokenWithBaseTax(
        uint256 bps
    ) internal returns (BoardwalkToken t, MockFeeDistributor fd) {
        fd = new MockFeeDistributor();
        t = _deployUninitializedToken();
        address[] memory exempts = new address[](0);
        t.initialize("Custom", "CT", bps, ANTI_WHALE_TAX_BPS, ANTI_WHALE_DURATION, address(fd), presaleManager, exempts);
    }

    /// @dev Mint tokens to `to` via the presaleManager
    function _mintTo(
        address to,
        uint256 amount
    ) internal {
        vm.prank(presaleManager);
        token.mint(to, amount);
    }

    /// @dev Set liquiditySeedTime to current block.timestamp via presaleManager
    function _seedLiquidity() internal {
        vm.prank(presaleManager);
        token.setLiquiditySeedTime(block.timestamp);
    }

    // ================================================================
    //  COVERAGE GAP TESTS
    // ================================================================

    function test_SetLiquiditySeedTime_ExactCurrentTimestamp() public {
        // seedTime == block.timestamp should succeed (boundary, not future)
        vm.prank(presaleManager);
        token.setLiquiditySeedTime(block.timestamp);
        assertEq(token.liquiditySeedTime(), block.timestamp, "Should accept exact current timestamp");
    }

    function test_RevertWhen_SetLiquiditySeedTime_FutureTime() public {
        vm.prank(presaleManager);
        vm.expectRevert(BoardwalkToken.FutureSeedTime.selector);
        token.setLiquiditySeedTime(block.timestamp + 1);
    }

    function test_UpdateExempt_ByFeeDistributor() public {
        assertFalse(token.isExempt(charlie), "charlie starts non-exempt");

        vm.prank(address(mockFeeDistributor));
        token.updateExempt(charlie, true);
        assertTrue(token.isExempt(charlie), "charlie should become exempt");

        vm.prank(address(mockFeeDistributor));
        token.updateExempt(charlie, false);
        assertFalse(token.isExempt(charlie), "charlie should be removable from exempt list");
    }

    function test_RevertWhen_UpdateExempt_NotFeeDistributor() public {
        vm.prank(alice);
        vm.expectRevert(BoardwalkToken.OnlyFeeDistributor.selector);
        token.updateExempt(charlie, true);
    }
}

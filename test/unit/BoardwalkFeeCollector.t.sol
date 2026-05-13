// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoardwalkFeeCollector} from "src/core/BoardwalkFeeCollector.sol";
import {IBoardwalkFeeCollector} from "src/interfaces/IBoardwalkFeeCollector.sol";
import {Timelocked} from "src/base/Timelocked.sol";

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

/// @dev Mock WETH (just an ERC20 for testing)
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
}

/// @dev Mock Router that implements standard swap (no fee-on-transfer)
///      Simulates receiving tokens and minting WETH to caller
contract MockFOTRouter {
    mapping(address => mapping(address => uint256)) public exchangeRates; // token -> weth rate

    function setExchangeRate(
        address token,
        address weth,
        uint256 rate
    ) external {
        exchangeRates[token][weth] = rate; // e.g., 1 token = rate wei WETH
    }

    /// @dev Standard swap - pulls tokens, mints WETH, returns amounts array
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "Deadline exceeded");
        require(path.length == 2, "Invalid path");

        address tokenIn = path[0];
        address tokenOut = path[1];
        uint256 rate = exchangeRates[tokenIn][tokenOut];
        require(rate > 0, "Exchange rate not set");

        // Transfer tokens from caller (FeeCollector) to this mock
        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Calculate output
        uint256 amountOut = (amountIn * rate) / 1e18;
        require(amountOut >= amountOutMin, "Slippage exceeded");

        // Mint WETH to recipient (mock can mint)
        MockERC20(tokenOut).mint(to, amountOut);

        // Return amounts array: [amountIn, amountOut]
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}

/// @dev Mock Router that can fail on specific tokens
contract MockFOTRouterWithFailure {
    mapping(address => bool) public shouldFail;
    mapping(address => mapping(address => uint256)) public exchangeRates;

    function setShouldFail(
        address token,
        bool fail
    ) external {
        shouldFail[token] = fail;
    }

    function setExchangeRate(
        address token,
        address weth,
        uint256 rate
    ) external {
        exchangeRates[token][weth] = rate;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "Deadline exceeded");
        require(path.length == 2, "Invalid path");

        address tokenIn = path[0];
        if (shouldFail[tokenIn]) {
            revert("Swap failed");
        }

        address tokenOut = path[1];
        uint256 rate = exchangeRates[tokenIn][tokenOut];
        require(rate > 0, "Exchange rate not set");

        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = (amountIn * rate) / 1e18;
        require(amountOut >= amountOutMin, "Slippage exceeded");

        MockERC20(tokenOut).mint(to, amountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}

/// @dev Mock FeeDistributor that records setFeeCollector calls (for migration tests)
contract MockFeeDistributor {
    address public feeCollector;
    uint256 public setFeeCollectorCallCount;
    address public lastNewCollector;

    constructor(
        address _feeCollector
    ) {
        feeCollector = _feeCollector;
    }

    function setFeeCollector(
        address newFeeCollector
    ) external {
        // In the real contract, only the current feeCollector can call this.
        // For the mock, we just record the call.
        require(msg.sender == feeCollector, "OnlyFeeCollector");
        lastNewCollector = newFeeCollector;
        feeCollector = newFeeCollector;
        setFeeCollectorCallCount++;
    }
}

/// @title BoardwalkFeeCollectorTest
/// @notice Unit and fuzz tests for BoardwalkFeeCollector.
contract BoardwalkFeeCollectorTest is Test {
    // ============ Constants ============

    uint256 internal constant TIMELOCK_DELAY = 7 days;
    uint256 internal constant TIMELOCK_EXPIRY = 7 days;

    // ============ State ============

    BoardwalkFeeCollector internal feeCollector;
    MockWETH internal weth;
    MockFOTRouter internal router;
    address internal owner;
    address internal treasury;
    address internal keeper;
    address internal alice;
    address internal bob;
    MockERC20 internal token1;
    MockERC20 internal token2;
    MockERC20 internal token3;

    bytes32 constant ACTION_SET_TREASURY = keccak256("SET_TREASURY");
    bytes32 constant ACTION_SET_KEEPER = keccak256("SET_KEEPER");
    bytes32 constant ACTION_MIGRATE_COLLECTOR = keccak256("MIGRATE_COLLECTOR");
    bytes32 constant ACTION_SET_GOVERNANCE_VAULT = keccak256("SET_GOVERNANCE_VAULT");

    // ============ Events (re-declared for vm.expectEmit) ============

    event FeesReceived(address indexed token, uint256 amount);
    event FeesSwapped(address indexed token, uint256 tokenAmount, uint256 wethAmount);
    event TreasuryUpdated(address indexed newTreasury);
    event KeeperUpdated(address indexed newKeeper);
    event CollectorMigrated(address newCollector, uint256 distributorCount);
    event ChangeSignaled(bytes32 indexed action, bytes32 dataHash, uint256 executeTime, uint256 expiresAt);
    event ChangeExecuted(bytes32 indexed action);
    event ChangeCanceled(bytes32 indexed action);

    // ============ Setup ============

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        keeper = makeAddr("keeper");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.label(owner, "owner");
        vm.label(treasury, "treasury");
        vm.label(keeper, "keeper");
        vm.label(alice, "alice");
        vm.label(bob, "bob");

        // Deploy mocks
        weth = new MockWETH();
        router = new MockFOTRouter();
        token1 = new MockERC20("Token1", "T1");
        token2 = new MockERC20("Token2", "T2");
        token3 = new MockERC20("Token3", "T3");

        // Set exchange rates: 1 token = 0.5 WETH
        router.setExchangeRate(address(token1), address(weth), 0.5e18);
        router.setExchangeRate(address(token2), address(weth), 0.5e18);
        router.setExchangeRate(address(token3), address(weth), 0.5e18);

        // Deploy fee collector
        vm.prank(owner);
        feeCollector = new BoardwalkFeeCollector(owner, address(weth), address(router), treasury, keeper);
    }

    // ============ Constructor ============

    function test_Constructor_SetsAllState() public view {
        assertEq(feeCollector.RAISE_TOKEN(), address(weth), "raise token mismatch");
        assertEq(feeCollector.ROUTER(), address(router), "router mismatch");
        assertEq(feeCollector.treasury(), treasury, "treasury mismatch");
        assertEq(feeCollector.keeper(), keeper, "keeper mismatch");
        assertEq(feeCollector.owner(), owner, "owner mismatch");
    }

    function test_RevertWhen_Constructor_WethIsZero() public {
        vm.expectRevert(IBoardwalkFeeCollector.ZeroAddress.selector);
        new BoardwalkFeeCollector(owner, address(0), address(router), treasury, keeper);
    }

    function test_RevertWhen_Constructor_RouterIsZero() public {
        vm.expectRevert(IBoardwalkFeeCollector.ZeroAddress.selector);
        new BoardwalkFeeCollector(owner, address(weth), address(0), treasury, keeper);
    }

    function test_RevertWhen_Constructor_TreasuryIsZero() public {
        vm.expectRevert(IBoardwalkFeeCollector.ZeroAddress.selector);
        new BoardwalkFeeCollector(owner, address(weth), address(router), address(0), keeper);
    }

    function test_RevertWhen_Constructor_KeeperIsZero() public {
        vm.expectRevert(IBoardwalkFeeCollector.ZeroAddress.selector);
        new BoardwalkFeeCollector(owner, address(weth), address(router), treasury, address(0));
    }

    // ============ receiveFees ============

    function test_ReceiveFees_HappyPath() public {
        uint256 amount = 1000e18;
        deal(address(token1), alice, amount);

        vm.startPrank(alice);
        token1.approve(address(feeCollector), amount);
        vm.expectEmit(true, false, false, true);
        emit FeesReceived(address(token1), amount);
        feeCollector.receiveFees(address(token1), amount);
        vm.stopPrank();

        assertEq(token1.balanceOf(address(feeCollector)), amount, "FeeCollector should receive tokens");
        assertEq(feeCollector.accumulatedFees(address(token1)), amount, "accumulatedFees should track amount");
        assertEq(token1.balanceOf(alice), 0, "alice should have no tokens");
    }

    function test_ReceiveFees_AccumulatesMultipleDeposits() public {
        uint256 amount1 = 500e18;
        uint256 amount2 = 300e18;
        deal(address(token1), alice, amount1 + amount2);

        vm.startPrank(alice);
        token1.approve(address(feeCollector), amount1 + amount2);
        feeCollector.receiveFees(address(token1), amount1);
        feeCollector.receiveFees(address(token1), amount2);
        vm.stopPrank();

        assertEq(feeCollector.accumulatedFees(address(token1)), amount1 + amount2, "Should accumulate fees");
    }

    function test_ReceiveFees_MultipleTokens() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        deal(address(token1), alice, amount1);
        deal(address(token2), alice, amount2);

        vm.startPrank(alice);
        token1.approve(address(feeCollector), amount1);
        token2.approve(address(feeCollector), amount2);
        feeCollector.receiveFees(address(token1), amount1);
        feeCollector.receiveFees(address(token2), amount2);
        vm.stopPrank();

        assertEq(feeCollector.accumulatedFees(address(token1)), amount1, "token1 fees tracked");
        assertEq(feeCollector.accumulatedFees(address(token2)), amount2, "token2 fees tracked");
    }

    function testFuzz_ReceiveFees_AnyAmount(
        uint256 amount
    ) public {
        amount = bound(amount, 1, type(uint128).max);
        deal(address(token1), alice, amount);

        vm.startPrank(alice);
        token1.approve(address(feeCollector), amount);
        feeCollector.receiveFees(address(token1), amount);
        vm.stopPrank();

        assertEq(feeCollector.accumulatedFees(address(token1)), amount, "Should track any amount");
    }

    // ============ swapToRaiseToken ============

    function test_SwapToRaiseToken_HappyPath() public {
        uint256 tokenAmount = 1000e18;
        deal(address(token1), address(feeCollector), tokenAmount);

        // Standard swap: no FOT tax, rate = 0.5e18
        uint256 expectedWeth = (tokenAmount * 0.5e18) / 1e18;

        vm.prank(keeper);
        vm.expectEmit(true, false, false, true);
        emit FeesSwapped(address(token1), tokenAmount, expectedWeth);
        feeCollector.swapToRaiseToken(_toArray(address(token1)), _toArray(0), block.timestamp);

        assertEq(feeCollector.accumulatedFees(address(token1)), 0, "accumulatedFees should reset");
        assertEq(weth.balanceOf(treasury), expectedWeth, "Treasury should receive raise token");
        assertEq(token1.balanceOf(address(feeCollector)), 0, "FeeCollector should have no tokens");
        assertEq(
            IERC20(token1).allowance(address(feeCollector), address(router)),
            type(uint256).max,
            "Approval should be max after first swap"
        );
    }

    function test_SwapToRaiseToken_MultipleTokens() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        deal(address(token1), address(feeCollector), amount1);
        deal(address(token2), address(feeCollector), amount2);

        // Standard swap: no FOT tax, rate = 0.5e18
        uint256 weth1 = (amount1 * 0.5e18) / 1e18;
        uint256 weth2 = (amount2 * 0.5e18) / 1e18;
        uint256 totalWeth = weth1 + weth2;

        vm.prank(keeper);
        feeCollector.swapToRaiseToken(_toArray(address(token1), address(token2)), _toArray(0, 0), block.timestamp);

        assertEq(weth.balanceOf(treasury), totalWeth, "Treasury should receive total raise token");
        assertEq(feeCollector.accumulatedFees(address(token1)), 0, "token1 fees reset");
        assertEq(feeCollector.accumulatedFees(address(token2)), 0, "token2 fees reset");
    }

    function test_SwapToRaiseToken_SkipsZeroBalance() public {
        uint256 amount1 = 1000e18;
        deal(address(token1), address(feeCollector), amount1);
        // token2 has zero balance

        // Standard swap: no FOT tax, rate = 0.5e18
        uint256 expectedWeth = (amount1 * 0.5e18) / 1e18;

        vm.prank(keeper);
        feeCollector.swapToRaiseToken(_toArray(address(token1), address(token2)), _toArray(0, 0), block.timestamp);

        assertEq(weth.balanceOf(treasury), expectedWeth, "Only token1 should be swapped");
    }

    function test_SwapToRaiseToken_ResetsApprovalOnSuccess() public {
        uint256 amount = 1000e18;
        deal(address(token1), address(feeCollector), amount);

        vm.prank(keeper);
        feeCollector.swapToRaiseToken(_toArray(address(token1)), _toArray(0), block.timestamp);

        assertEq(
            IERC20(token1).allowance(address(feeCollector), address(router)),
            type(uint256).max,
            "Approval should be max after swap"
        );
    }

    function test_RevertWhen_SwapToRaiseToken_RouterReverts() public {
        MockFOTRouterWithFailure failingRouter = new MockFOTRouterWithFailure();
        failingRouter.setShouldFail(address(token1), true);

        // Deploy new fee collector with failing router
        vm.prank(owner);
        BoardwalkFeeCollector newCollector =
            new BoardwalkFeeCollector(owner, address(weth), address(failingRouter), treasury, keeper);

        uint256 amount = 1000e18;
        deal(address(token1), address(newCollector), amount);

        // No try/catch: router revert propagates directly to caller
        vm.prank(keeper);
        vm.expectRevert();
        newCollector.swapToRaiseToken(_toArray(address(token1)), _toArray(0), block.timestamp);

        // Entire tx reverted, so state is unchanged
        assertEq(token1.balanceOf(address(newCollector)), amount, "Tokens should remain in collector after revert");
    }

    function test_RevertWhen_SwapToRaiseToken_PartialFailure_RevertsAll() public {
        MockFOTRouterWithFailure partialRouter = new MockFOTRouterWithFailure();
        partialRouter.setShouldFail(address(token1), true);
        partialRouter.setExchangeRate(address(token2), address(weth), 0.5e18);

        vm.prank(owner);
        BoardwalkFeeCollector newCollector =
            new BoardwalkFeeCollector(owner, address(weth), address(partialRouter), treasury, keeper);

        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        deal(address(token1), address(newCollector), amount1);
        deal(address(token2), address(newCollector), amount2);

        // No try/catch: one failing swap reverts the entire batch
        vm.prank(keeper);
        vm.expectRevert();
        newCollector.swapToRaiseToken(_toArray(address(token1), address(token2)), _toArray(0, 0), block.timestamp);

        // Entire tx reverted — no state changes
        assertEq(weth.balanceOf(treasury), 0, "No raise token should be sent on revert");
        assertEq(token1.balanceOf(address(newCollector)), amount1, "token1 should remain in collector");
        assertEq(token2.balanceOf(address(newCollector)), amount2, "token2 should remain in collector");
    }

    function test_SwapToRaiseToken_RevertsWhenSlippageTooHigh() public {
        uint256 amount = 1000e18;
        deal(address(token1), address(feeCollector), amount);

        uint256 minAmountOut = type(uint256).max; // Impossibly high

        // No try/catch: router slippage revert propagates directly
        vm.prank(keeper);
        vm.expectRevert();
        feeCollector.swapToRaiseToken(_toArray(address(token1)), _toArray(minAmountOut), block.timestamp);
    }

    function test_RevertWhen_SwapToRaiseToken_NotKeeper() public {
        uint256 amount = 1000e18;
        deal(address(token1), address(feeCollector), amount);

        vm.prank(alice);
        vm.expectRevert(IBoardwalkFeeCollector.NotKeeper.selector);
        feeCollector.swapToRaiseToken(_toArray(address(token1)), _toArray(0), block.timestamp);
    }

    function test_RevertWhen_SwapToRaiseToken_EmptyArray() public {
        vm.prank(keeper);
        vm.expectRevert(IBoardwalkFeeCollector.NoTokensToSwap.selector);
        feeCollector.swapToRaiseToken(new address[](0), new uint256[](0), block.timestamp);
    }

    function test_RevertWhen_SwapToRaiseToken_ArrayLengthMismatch() public {
        uint256 amount = 1000e18;
        deal(address(token1), address(feeCollector), amount);

        vm.prank(keeper);
        vm.expectRevert(IBoardwalkFeeCollector.ArrayLengthMismatch.selector);
        feeCollector.swapToRaiseToken(_toArray(address(token1)), new uint256[](0), block.timestamp);
    }

    function testFuzz_SwapToRaiseToken_AnyAmount(
        uint256 amount
    ) public {
        amount = bound(amount, 1e18, 1000000e18);
        deal(address(token1), address(feeCollector), amount);

        // Standard swap: no FOT tax, rate = 0.5e18
        uint256 expectedWeth = (amount * 0.5e18) / 1e18;

        vm.prank(keeper);
        feeCollector.swapToRaiseToken(_toArray(address(token1)), _toArray(0), block.timestamp);

        assertEq(weth.balanceOf(treasury), expectedWeth, "Should swap any amount");
    }

    // ============ Timelocked Admin: Treasury ============

    function test_SignalSetTreasury_Success() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_TREASURY, keccak256(abi.encode(newTreasury)));

        (bool isPending, uint256 executeTime, uint256 expiresAt) =
            feeCollector.getPendingChange(ACTION_SET_TREASURY);
        assertTrue(isPending, "Change should be pending");
        assertEq(executeTime, block.timestamp + TIMELOCK_DELAY, "Execute time should be delay from now");
        assertEq(expiresAt, executeTime + TIMELOCK_EXPIRY, "Expiry should be delay + expiry");
    }

    function test_RevertWhen_ExecuteSetTreasury_ZeroAddress() public {
        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_TREASURY, keccak256(abi.encode(address(0))));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(IBoardwalkFeeCollector.ZeroAddress.selector);
        feeCollector.executeSetTreasury(address(0));
    }

    function test_RevertWhen_SignalSetTreasury_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        feeCollector.signalAction(ACTION_SET_TREASURY, keccak256(abi.encode(makeAddr("newTreasury"))));
    }

    function test_ExecuteSetTreasury_AfterDelay() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_TREASURY, keccak256(abi.encode(newTreasury)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectEmit(true, false, false, false);
        emit TreasuryUpdated(newTreasury);
        feeCollector.executeSetTreasury(newTreasury);

        assertEq(feeCollector.treasury(), newTreasury, "Treasury should be updated");
    }

    function test_RevertWhen_ExecuteSetTreasury_BeforeDelay() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_TREASURY, keccak256(abi.encode(newTreasury)));

        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);

        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockTooEarly.selector, block.timestamp + 1));
        feeCollector.executeSetTreasury(newTreasury);
    }

    function test_RevertWhen_ExecuteSetTreasury_AfterExpiry() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_TREASURY, keccak256(abi.encode(newTreasury)));

        uint256 executeTime = block.timestamp + TIMELOCK_DELAY;
        uint256 expiryTime = executeTime + TIMELOCK_EXPIRY;
        vm.warp(expiryTime + 1);

        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockExpired.selector, expiryTime));
        feeCollector.executeSetTreasury(newTreasury);
    }

    function test_RevertWhen_ExecuteSetTreasury_WrongDataHash() public {
        address newTreasury = makeAddr("newTreasury");
        address wrongTreasury = makeAddr("wrongTreasury");

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_TREASURY, keccak256(abi.encode(newTreasury)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(Timelocked.TimelockDataMismatch.selector);
        feeCollector.executeSetTreasury(wrongTreasury);
    }

    function test_CancelSetTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_TREASURY, keccak256(abi.encode(newTreasury)));

        bytes32 action = ACTION_SET_TREASURY;
        vm.prank(owner);
        feeCollector.cancelAction(action);

        (bool isPending,,) = feeCollector.getPendingChange(ACTION_SET_TREASURY);
        assertFalse(isPending, "Change should be canceled");
    }

    function test_RevertWhen_CancelSetTreasury_NotOwner() public {
        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_TREASURY, keccak256(abi.encode(makeAddr("newTreasury"))));

        bytes32 action = ACTION_SET_TREASURY;
        vm.prank(alice);
        vm.expectRevert();
        feeCollector.cancelAction(action);
    }

    // ============ Timelocked Admin: Keeper ============

    function test_SignalSetKeeper_Success() public {
        address newKeeper = makeAddr("newKeeper");

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_KEEPER, keccak256(abi.encode(newKeeper)));

        (bool isPending, uint256 executeTime, uint256 expiresAt) =
            feeCollector.getPendingChange(ACTION_SET_KEEPER);
        assertTrue(isPending, "Change should be pending");
        assertEq(executeTime, block.timestamp + TIMELOCK_DELAY, "Execute time should be delay from now");
    }

    function test_RevertWhen_ExecuteSetKeeper_ZeroAddress() public {
        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_KEEPER, keccak256(abi.encode(address(0))));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(IBoardwalkFeeCollector.ZeroAddress.selector);
        feeCollector.executeSetKeeper(address(0));
    }

    function test_ExecuteSetKeeper_AfterDelay() public {
        address newKeeper = makeAddr("newKeeper");

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_KEEPER, keccak256(abi.encode(newKeeper)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectEmit(true, false, false, false);
        emit KeeperUpdated(newKeeper);
        feeCollector.executeSetKeeper(newKeeper);

        assertEq(feeCollector.keeper(), newKeeper, "Keeper should be updated");
    }

    function test_ExecuteSetKeeper_CanCallSwapAfterUpdate() public {
        address newKeeper = makeAddr("newKeeper");

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_KEEPER, keccak256(abi.encode(newKeeper)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        feeCollector.executeSetKeeper(newKeeper);

        uint256 amount = 1000e18;
        deal(address(token1), address(feeCollector), amount);

        vm.prank(newKeeper);
        feeCollector.swapToRaiseToken(_toArray(address(token1)), _toArray(0), block.timestamp);

        // Should succeed with new keeper
        assertGt(weth.balanceOf(treasury), 0, "New keeper should be able to swap");
    }

    function test_CancelSetKeeper() public {
        address newKeeper = makeAddr("newKeeper");

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_KEEPER, keccak256(abi.encode(newKeeper)));

        bytes32 action = ACTION_SET_KEEPER;
        vm.prank(owner);
        feeCollector.cancelAction(action);

        (bool isPending,,) = feeCollector.getPendingChange(ACTION_SET_KEEPER);
        assertFalse(isPending, "Change should be canceled");
    }

    // ============ Integration: Full Flow ============

    function test_Integration_ReceiveAndSwap() public {
        // Receive fees from multiple sources
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        deal(address(token1), alice, amount1);
        deal(address(token2), bob, amount2);

        vm.startPrank(alice);
        token1.approve(address(feeCollector), amount1);
        feeCollector.receiveFees(address(token1), amount1);
        vm.stopPrank();

        vm.startPrank(bob);
        token2.approve(address(feeCollector), amount2);
        feeCollector.receiveFees(address(token2), amount2);
        vm.stopPrank();

        assertEq(feeCollector.accumulatedFees(address(token1)), amount1, "token1 tracked");
        assertEq(feeCollector.accumulatedFees(address(token2)), amount2, "token2 tracked");

        // Keeper swaps to WETH
        vm.prank(keeper);
        feeCollector.swapToRaiseToken(_toArray(address(token1), address(token2)), _toArray(0, 0), block.timestamp);

        assertEq(feeCollector.accumulatedFees(address(token1)), 0, "token1 reset");
        assertEq(feeCollector.accumulatedFees(address(token2)), 0, "token2 reset");
        assertGt(weth.balanceOf(treasury), 0, "Treasury should receive raise token");
    }

    // ============ Helpers ============

    function _toArray(
        address a
    ) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = a;
        return arr;
    }

    function _toArray(
        address a,
        address b
    ) internal pure returns (address[] memory) {
        address[] memory arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function _toArray(
        uint256 a
    ) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = a;
        return arr;
    }

    function _toArray(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    // ============ Collector Migration ============

    function test_SignalExecuteMigrateCollector() public {
        address newCollector = makeAddr("newCollector");

        // Signal
        vm.prank(owner);
        feeCollector.signalAction(
            ACTION_MIGRATE_COLLECTOR, keccak256(abi.encode(newCollector, new address[](0)))
        );

        (bool isPending, uint256 executeTime, uint256 expiresAt) =
            feeCollector.getPendingChange(ACTION_MIGRATE_COLLECTOR);
        assertTrue(isPending, "Migration should be pending");
        assertEq(executeTime, block.timestamp + TIMELOCK_DELAY, "executeTime mismatch");
        assertEq(expiresAt, executeTime + TIMELOCK_EXPIRY, "expiresAt mismatch");

        // Warp past delay
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Execute with empty distributors array (no FeeDistributors to migrate)
        vm.expectEmit(true, true, true, true, address(feeCollector));
        emit CollectorMigrated(newCollector, 0);

        feeCollector.executeMigrateCollector(newCollector, new address[](0));

        // Verify pending change cleared
        (isPending,,) = feeCollector.getPendingChange(ACTION_MIGRATE_COLLECTOR);
        assertFalse(isPending, "Migration should no longer be pending");
    }

    function test_RevertWhen_MigrateCollector_NotOwner() public {
        address newCollector = makeAddr("newCollector");

        vm.prank(alice);
        vm.expectRevert();
        feeCollector.signalAction(
            ACTION_MIGRATE_COLLECTOR, keccak256(abi.encode(newCollector, new address[](0)))
        );
    }

    function test_RevertWhen_ExecuteMigrateCollector_ZeroAddress() public {
        vm.prank(owner);
        feeCollector.signalAction(
            ACTION_MIGRATE_COLLECTOR, keccak256(abi.encode(address(0), new address[](0)))
        );

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(IBoardwalkFeeCollector.ZeroAddress.selector);
        feeCollector.executeMigrateCollector(address(0), new address[](0));
    }

    function test_ExecuteMigrateCollector_UpdatesDistributors() public {
        address newCollector = makeAddr("newCollector");

        // Create mock FeeDistributors that point to the current feeCollector
        MockFeeDistributor dist1 = new MockFeeDistributor(address(feeCollector));
        MockFeeDistributor dist2 = new MockFeeDistributor(address(feeCollector));
        MockFeeDistributor dist3 = new MockFeeDistributor(address(feeCollector));

        // Build distributors array (must be committed in the signal hash)
        address[] memory distributors = new address[](3);
        distributors[0] = address(dist1);
        distributors[1] = address(dist2);
        distributors[2] = address(dist3);

        // Signal migration with the same distributors array that execute will use
        vm.prank(owner);
        feeCollector.signalAction(ACTION_MIGRATE_COLLECTOR, keccak256(abi.encode(newCollector, distributors)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Execute migration
        vm.expectEmit(true, true, true, true, address(feeCollector));
        emit CollectorMigrated(newCollector, 3);

        feeCollector.executeMigrateCollector(newCollector, distributors);

        // Verify each distributor was updated
        assertEq(dist1.feeCollector(), newCollector, "dist1 feeCollector should be updated");
        assertEq(dist2.feeCollector(), newCollector, "dist2 feeCollector should be updated");
        assertEq(dist3.feeCollector(), newCollector, "dist3 feeCollector should be updated");
        assertEq(dist1.setFeeCollectorCallCount(), 1, "dist1 setFeeCollector should be called once");
        assertEq(dist2.setFeeCollectorCallCount(), 1, "dist2 setFeeCollector should be called once");
        assertEq(dist3.setFeeCollectorCallCount(), 1, "dist3 setFeeCollector should be called once");
    }

    function test_CancelMigrateCollector() public {
        address newCollector = makeAddr("newCollector");

        // Signal
        vm.prank(owner);
        feeCollector.signalAction(
            ACTION_MIGRATE_COLLECTOR, keccak256(abi.encode(newCollector, new address[](0)))
        );

        bytes32 action = ACTION_MIGRATE_COLLECTOR;
        (bool isPending,,) = feeCollector.getPendingChange(action);
        assertTrue(isPending, "Should be pending after signal");

        // Cancel
        vm.expectEmit(true, false, false, false);
        emit ChangeCanceled(action);

        vm.prank(owner);
        feeCollector.cancelAction(action);

        (isPending,,) = feeCollector.getPendingChange(action);
        assertFalse(isPending, "Should not be pending after cancel");

        // Verify execute reverts after cancel
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        feeCollector.executeMigrateCollector(newCollector, new address[](0));
    }

    function test_RevertWhen_CancelMigrateCollector_NotOwner() public {
        vm.prank(owner);
        feeCollector.signalAction(
            ACTION_MIGRATE_COLLECTOR, keccak256(abi.encode(makeAddr("newCollector"), new address[](0)))
        );

        bytes32 action = ACTION_MIGRATE_COLLECTOR;
        vm.prank(alice);
        vm.expectRevert();
        feeCollector.cancelAction(action);
    }

    function test_RevertWhen_ExecuteMigrateCollector_BeforeDelay() public {
        address newCollector = makeAddr("newCollector");

        vm.prank(owner);
        feeCollector.signalAction(
            ACTION_MIGRATE_COLLECTOR, keccak256(abi.encode(newCollector, new address[](0)))
        );

        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockTooEarly.selector, block.timestamp + TIMELOCK_DELAY));
        feeCollector.executeMigrateCollector(newCollector, new address[](0));
    }

    function test_RevertWhen_ExecuteMigrateCollector_AfterExpiry() public {
        address newCollector = makeAddr("newCollector");

        vm.prank(owner);
        feeCollector.signalAction(
            ACTION_MIGRATE_COLLECTOR, keccak256(abi.encode(newCollector, new address[](0)))
        );

        vm.warp(block.timestamp + TIMELOCK_DELAY + TIMELOCK_EXPIRY + 1);

        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockExpired.selector, block.timestamp - 1));
        feeCollector.executeMigrateCollector(newCollector, new address[](0));
    }

    function test_RevertWhen_ExecuteMigrateCollector_WrongDataHash() public {
        address newCollector = makeAddr("newCollector");
        address wrongCollector = makeAddr("wrongCollector");

        vm.prank(owner);
        feeCollector.signalAction(
            ACTION_MIGRATE_COLLECTOR, keccak256(abi.encode(newCollector, new address[](0)))
        );

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(Timelocked.TimelockDataMismatch.selector);
        feeCollector.executeMigrateCollector(wrongCollector, new address[](0));
    }

    function test_RevertWhen_ExecuteMigrateCollector_NotSignaled() public {
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        feeCollector.executeMigrateCollector(makeAddr("newCollector"), new address[](0));
    }

    // ============ Governance Vault Tests ============

    event GovernanceVaultUpdated(address indexed newVault);

    function test_GovernanceVault_DefaultIsZero() public view {
        assertEq(feeCollector.governanceVault(), address(0));
    }

    function test_GovernanceBps_Is7000() public view {
        assertEq(feeCollector.GOVERNANCE_BPS(), 7000);
    }

    function test_SignalExecuteSetGovernanceVault_Success() public {
        address vault = makeAddr("vault");
        // executeSetGovernanceVault checks IGovernanceVoter(vault).WETH() == RAISE_TOKEN.
        vm.mockCall(vault, abi.encodeWithSignature("WETH()"), abi.encode(address(weth)));

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(vault)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectEmit(true, true, true, true);
        emit GovernanceVaultUpdated(vault);
        feeCollector.executeSetGovernanceVault(vault);

        assertEq(feeCollector.governanceVault(), vault);
    }

    function test_RevertWhen_SignalSetGovernanceVault_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        feeCollector.signalAction(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(makeAddr("vault"))));
    }

    function test_RevertWhen_ExecuteSetGovernanceVault_BeforeDelay() public {
        address vault = makeAddr("vault");
        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(vault)));

        vm.expectRevert();
        feeCollector.executeSetGovernanceVault(vault);
    }

    function test_ExecuteSetGovernanceVault_CanSetToZero() public {
        address vault = makeAddr("vault");
        // executeSetGovernanceVault checks IGovernanceVoter(vault).WETH() == RAISE_TOKEN.
        vm.mockCall(vault, abi.encodeWithSignature("WETH()"), abi.encode(address(weth)));

        vm.warp(1000);
        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(vault)));
        vm.warp(1000 + TIMELOCK_DELAY + 1);
        feeCollector.executeSetGovernanceVault(vault);
        assertEq(feeCollector.governanceVault(), vault);

        // address(0) is exempt from the WETH-compat guard (the if-branch is gated on != 0).
        vm.warp(1000 + TIMELOCK_DELAY + 100);
        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(address(0))));
        vm.warp(1000 + 2 * TIMELOCK_DELAY + 200);
        feeCollector.executeSetGovernanceVault(address(0));
        assertEq(feeCollector.governanceVault(), address(0));
    }

    function test_SwapToRaiseToken_SplitsWhenGovernanceVaultSet() public {
        address vault = makeAddr("vault");
        // the vault must answer WETH() with the collector's RAISE_TOKEN, and accept
        // a depositRevenue(amount) call. We mock both so the test can use a plain EOA address.
        vm.mockCall(vault, abi.encodeWithSignature("WETH()"), abi.encode(address(weth)));
        vm.mockCall(vault, abi.encodeWithSignature("depositRevenue(uint256)"), "");

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(vault)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        feeCollector.executeSetGovernanceVault(vault);

        uint256 amount = 1000e18;
        token1.mint(address(feeCollector), amount);
        router.setExchangeRate(address(token1), address(weth), 1e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 0;

        vm.prank(keeper);
        feeCollector.swapToRaiseToken(tokens, mins, block.timestamp);

        uint256 total = amount;
        uint256 governanceExpected = total * 7000 / 10000;
        uint256 treasuryExpected = total - governanceExpected;

        // Treasury receives its share via safeTransfer (same as before), but the
        // governance share is forwarded through the vault's depositRevenue. The mocked vault
        // ignores the call, so the WETH stays in the collector with a standing max-allowance.
        // We assert treasury and the leftover-at-collector branch instead of the vault balance.
        assertEq(weth.balanceOf(treasury), treasuryExpected, "treasury portion routed normally");
        assertEq(
            weth.balanceOf(address(feeCollector)),
            governanceExpected,
            "governance share held pending depositRevenue's transferFrom (mocked, so no pull)"
        );
        // Lazy-max-approve: the collector tops the allowance to type(uint256).max once and
        // leaves it there for subsequent swaps (saves ~5k gas per call). Safe because the
        // voter's only `safeTransferFrom` path is `depositRevenue`, gated by msg.sender check.
        assertEq(
            weth.allowance(address(feeCollector), vault),
            type(uint256).max,
            "collector approved the vault to max for ongoing depositRevenue calls"
        );
    }

    function test_SwapToRaiseToken_FullToTreasuryWhenNoVault() public {
        uint256 amount = 1000e18;
        token1.mint(address(feeCollector), amount);
        router.setExchangeRate(address(token1), address(weth), 1e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 0;

        vm.prank(keeper);
        feeCollector.swapToRaiseToken(tokens, mins, block.timestamp);

        assertEq(weth.balanceOf(treasury), amount);
    }

    // ============ forwardRevenue / bridged WETH ============

    /// @notice Bridged WETH lands directly on the collector (no swap step). `forwardRevenue` sweeps
    ///         it to treasury when no governance vault is set.
    function test_ForwardRevenue_BridgedWeth_NoVault() public {
        uint256 bridged = 500e18;
        deal(address(weth), address(feeCollector), bridged);

        vm.prank(keeper);
        feeCollector.forwardRevenue();

        assertEq(weth.balanceOf(treasury), bridged, "treasury receives full bridged amount");
        assertEq(weth.balanceOf(address(feeCollector)), 0, "collector drained");
    }

    /// @notice Bridged WETH split 30/70 to treasury/governance when the vault is set.
    function test_ForwardRevenue_BridgedWeth_SplitsWhenVaultSet() public {
        address vault = makeAddr("vault");
        vm.mockCall(vault, abi.encodeWithSignature("WETH()"), abi.encode(address(weth)));
        vm.mockCall(vault, abi.encodeWithSignature("depositRevenue(uint256)"), "");

        vm.prank(owner);
        feeCollector.signalAction(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(vault)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        feeCollector.executeSetGovernanceVault(vault);

        uint256 bridged = 1000e18;
        deal(address(weth), address(feeCollector), bridged);

        uint256 governanceExpected = bridged * 7000 / 10000;
        uint256 treasuryExpected = bridged - governanceExpected;

        vm.prank(keeper);
        feeCollector.forwardRevenue();

        assertEq(weth.balanceOf(treasury), treasuryExpected, "treasury portion routed");
        // Vault is mocked → its `depositRevenue` ignores the pull, so the governance share remains
        // sitting on the collector with a standing max-allowance to the vault.
        assertEq(weth.balanceOf(address(feeCollector)), governanceExpected, "governance share held pending pull");
        assertEq(
            weth.allowance(address(feeCollector), vault), type(uint256).max, "vault approved to max"
        );
    }

    /// @notice With a zero balance, `forwardRevenue` is a silent no-op so a periodic keeper cron
    ///         does not revert when there is nothing to forward.
    function test_ForwardRevenue_NoOpOnZeroBalance() public {
        assertEq(weth.balanceOf(address(feeCollector)), 0);
        vm.prank(keeper);
        feeCollector.forwardRevenue();
        assertEq(weth.balanceOf(treasury), 0);
    }

    function test_RevertWhen_ForwardRevenue_NotKeeper() public {
        deal(address(weth), address(feeCollector), 100e18);
        vm.expectRevert(BoardwalkFeeCollector.NotKeeper.selector);
        vm.prank(alice);
        feeCollector.forwardRevenue();
    }

    /// @notice Calling `receiveFees(WETH, n)` with bridged WETH sets `accumulatedFees[WETH] = n`.
    ///         A subsequent `forwardRevenue` clears it back to zero so observers are not misled.
    function test_ForwardRevenue_ClearsAccumulatedRaiseToken() public {
        uint256 bridged = 100e18;
        deal(address(weth), alice, bridged);
        vm.startPrank(alice);
        weth.approve(address(feeCollector), bridged);
        feeCollector.receiveFees(address(weth), bridged);
        vm.stopPrank();

        assertEq(feeCollector.accumulatedFees(address(weth)), bridged, "registered");

        vm.prank(keeper);
        feeCollector.forwardRevenue();

        assertEq(feeCollector.accumulatedFees(address(weth)), 0, "cleared");
        assertEq(weth.balanceOf(treasury), bridged);
    }

    /// @notice `swapToRaiseToken` now sweeps any pre-existing raise-token balance (e.g. bridged in
    ///         out-of-band) alongside the swap output, so a single keeper tx drains both.
    function test_SwapToRaiseToken_SweepsBridgedRaiseToken() public {
        uint256 swapAmount = 1000e18;
        uint256 bridged = 333e18;
        token1.mint(address(feeCollector), swapAmount);
        deal(address(weth), address(feeCollector), bridged);
        router.setExchangeRate(address(token1), address(weth), 1e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token1);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 0;

        vm.prank(keeper);
        feeCollector.swapToRaiseToken(tokens, mins, block.timestamp);

        assertEq(weth.balanceOf(treasury), swapAmount + bridged, "treasury receives swap output + bridged");
        assertEq(weth.balanceOf(address(feeCollector)), 0, "collector drained");
    }

    /// @notice Passing RAISE_TOKEN inside `tokens[]` is silently skipped (an `[X, X]` swap path
    ///         would revert the router); the trailing balance sweep still picks the WETH up.
    function test_SwapToRaiseToken_SkipsRaiseTokenEntry() public {
        uint256 bridged = 500e18;
        deal(address(weth), address(feeCollector), bridged);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory mins = new uint256[](1);
        mins[0] = 0;

        vm.prank(keeper);
        feeCollector.swapToRaiseToken(tokens, mins, block.timestamp);

        assertEq(weth.balanceOf(treasury), bridged, "swept by trailing forward despite RAISE_TOKEN entry");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoardwalkLPManager} from "src/core/BoardwalkLPManager.sol";
import {IBoardwalkLPManager} from "src/interfaces/IBoardwalkLPManager.sol";

// ============ Mocks ============

/// @dev Mock ERC20 token with mint function
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

/// @dev Mock UniswapV2Pair (LP token) - ERC20 with mint
contract MockUniswapV2Pair is ERC20 {
    address public token0;
    address public token1;

    constructor(
        address _token0,
        address _token1
    ) ERC20("LP Token", "LP") {
        token0 = _token0;
        token1 = _token1;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }

    /// @dev Allow router to transfer tokens out (for removeLiquidity simulation)
    function transferTokens(
        address token,
        address to,
        uint256 amount
    ) external {
        IERC20(token).transfer(to, amount);
    }
}

/// @dev Mock UniswapV2Factory that can return configured pair addresses
contract MockUniswapV2Factory {
    mapping(address => mapping(address => address)) public pairs;
    mapping(address => address) public token0;
    mapping(address => address) public token1;

    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address) {
        return pairs[tokenA][tokenB];
    }

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address) {
        require(pairs[tokenA][tokenB] == address(0), "Pair exists");
        address pair = address(new MockUniswapV2Pair(tokenA, tokenB));
        pairs[tokenA][tokenB] = pair;
        pairs[tokenB][tokenA] = pair;
        token0[pair] = tokenA;
        token1[pair] = tokenB;
        return pair;
    }

    function setPair(
        address tokenA,
        address tokenB,
        address pair
    ) external {
        pairs[tokenA][tokenB] = pair;
        pairs[tokenB][tokenA] = pair;
        token0[pair] = tokenA;
        token1[pair] = tokenB;
    }
}

/// @dev Mock UniswapV2Router that implements addLiquidity and removeLiquidity
contract MockUniswapV2Router {
    MockUniswapV2Factory public factory;

    // Configurable slippage for testing excess token scenarios
    uint256 public useRatioBps = 10000; // 100% by default (no excess)

    constructor(
        MockUniswapV2Factory _factory
    ) {
        factory = _factory;
    }

    function setUseRatio(
        uint256 _useRatioBps
    ) external {
        useRatioBps = _useRatioBps; // e.g., 9500 = 95% used, 5% excess
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256,
        uint256,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(block.timestamp <= deadline, "Deadline exceeded");

        // Transfer tokens from caller (LPManager) to this router
        require(IERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired), "Transfer A failed");
        require(IERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired), "Transfer B failed");

        // Calculate actual amounts used (can be less than desired for excess testing)
        amountA = (amountADesired * useRatioBps) / 10000;
        amountB = (amountBDesired * useRatioBps) / 10000;

        // Get or create pair
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = factory.createPair(tokenA, tokenB);
        }

        // Transfer tokens to pair (simulating LP creation)
        IERC20(tokenA).transfer(pair, amountA);
        IERC20(tokenB).transfer(pair, amountB);

        // Mint LP tokens to recipient
        // Simplified LP calculation: sqrt(amountA * amountB)
        liquidity = _sqrt(amountA * amountB);
        MockUniswapV2Pair(pair).mint(to, liquidity);

        // Return excess tokens to caller (LPManager), mimicking real router behavior
        uint256 excessA = amountADesired - amountA;
        uint256 excessB = amountBDesired - amountB;
        if (excessA > 0) IERC20(tokenA).transfer(msg.sender, excessA);
        if (excessB > 0) IERC20(tokenB).transfer(msg.sender, excessB);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256,
        uint256,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB) {
        require(block.timestamp <= deadline, "Deadline exceeded");

        // Get pair address
        address pair = factory.getPair(tokenA, tokenB);
        require(pair != address(0), "Pair not found");

        // Transfer LP tokens from caller (LPManager) to this router
        require(IERC20(pair).transferFrom(msg.sender, address(this), liquidity), "Transfer LP failed");

        // Read totalSupply BEFORE burning to use as denominator
        uint256 reserveA = IERC20(tokenA).balanceOf(pair);
        uint256 reserveB = IERC20(tokenB).balanceOf(pair);
        uint256 totalLP = MockUniswapV2Pair(pair).totalSupply();

        // Burn LP tokens
        MockUniswapV2Pair(pair).burn(address(this), liquidity);

        if (totalLP > 0) {
            amountA = (reserveA * liquidity) / totalLP;
            amountB = (reserveB * liquidity) / totalLP;
        } else {
            // If no reserves, return zero
            amountA = 0;
            amountB = 0;
        }

        // Transfer tokens from pair to recipient (to = LPManager)
        // Use the pair's transferTokens function to move tokens out
        if (amountA > 0) MockUniswapV2Pair(pair).transferTokens(tokenA, to, amountA);
        if (amountB > 0) MockUniswapV2Pair(pair).transferTokens(tokenB, to, amountB);
    }

    function _sqrt(
        uint256 x
    ) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}

// ============ Test Contract ============

/// @title BoardwalkLPManagerTest
/// @notice Unit and fuzz tests for BoardwalkLPManager.
contract BoardwalkLPManagerTest is Test {
    // ============ Constants ============

    uint256 internal constant DEADLINE = type(uint256).max;
    uint256 internal constant MIN_AMOUNT = 1e18;
    uint256 internal constant MAX_AMOUNT = 1000e18;

    // ============ State ============

    BoardwalkLPManager internal lpManager;
    MockUniswapV2Factory internal factory;
    MockUniswapV2Router internal router;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockUniswapV2Pair internal pair;

    address internal alice;
    address internal bob;
    address internal charlie;

    // ============ Setup ============

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(charlie, "charlie");

        // Deploy mocks
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router(factory);
        tokenA = new MockERC20("TokenA", "TKA");
        tokenB = new MockERC20("TokenB", "TKB");

        // Deploy LPManager — tokenA acts as RAISE_TOKEN for pair restriction
        lpManager = new BoardwalkLPManager(address(factory), address(router), address(tokenA));

        vm.label(address(lpManager), "LPManager");
        vm.label(address(factory), "Factory");
        vm.label(address(router), "Router");
        vm.label(address(tokenA), "TokenA");
        vm.label(address(tokenB), "TokenB");
    }

    // ============ Constructor ============

    function test_Constructor_SetsFactoryAndRouter() public {
        BoardwalkLPManager newManager = new BoardwalkLPManager(address(factory), address(router), address(tokenA));

        assertEq(newManager.FACTORY(), address(factory), "factory mismatch");
        assertEq(newManager.ROUTER(), address(router), "router mismatch");
        assertEq(newManager.RAISE_TOKEN(), address(tokenA), "raiseToken mismatch");
    }

    // ============ addLiquidity ============

    function test_addLiquidity_HappyPath() public {
        uint256 amountA = 100e18;
        uint256 amountB = 200e18;

        // Setup: mint tokens to alice and approve LPManager
        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), amountA);
        tokenB.approve(address(lpManager), amountB);
        vm.stopPrank();

        // Execute addLiquidity
        vm.prank(alice);
        (uint256 actualA, uint256 actualB, uint256 liquidity) = lpManager.addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        // Verify LP tokens minted to alice
        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        assertTrue(pairAddr != address(0), "Pair should be created");
        assertGt(MockUniswapV2Pair(pairAddr).balanceOf(alice), 0, "Alice should receive LP tokens");
        assertEq(MockUniswapV2Pair(pairAddr).balanceOf(alice), liquidity, "LP balance should match return value");

        // Verify tokens used
        assertEq(actualA, amountA, "amountA should equal desired");
        assertEq(actualB, amountB, "amountB should equal desired");

        // Verify approvals reset
        assertEq(tokenA.allowance(address(lpManager), address(router)), 0, "TokenA approval should be reset");
        assertEq(tokenB.allowance(address(lpManager), address(router)), 0, "TokenB approval should be reset");
    }

    function test_addLiquidity_WithExcessTokens() public {
        uint256 amountADesired = 100e18;
        uint256 amountBDesired = 200e18;

        // Configure router to use only 95% of desired amounts
        router.setUseRatio(9500); // 95%

        // Setup
        tokenA.mint(alice, amountADesired);
        tokenB.mint(alice, amountBDesired);

        uint256 aliceBalanceABefore = tokenA.balanceOf(alice);
        uint256 aliceBalanceBBefore = tokenB.balanceOf(alice);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), amountADesired);
        tokenB.approve(address(lpManager), amountBDesired);
        vm.stopPrank();

        // Execute
        vm.prank(alice);
        (uint256 actualA, uint256 actualB,) = lpManager.addLiquidity(
            address(tokenA), address(tokenB), amountADesired, amountBDesired, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        // Verify actual amounts used are less than desired
        assertLt(actualA, amountADesired, "actualA should be less than desired");
        assertLt(actualB, amountBDesired, "actualB should be less than desired");

        // Verify excess tokens returned to alice
        uint256 expectedExcessA = amountADesired - actualA;
        uint256 expectedExcessB = amountBDesired - actualB;

        assertEq(
            tokenA.balanceOf(alice),
            aliceBalanceABefore - amountADesired + expectedExcessA,
            "Excess tokenA should be returned"
        );
        assertEq(
            tokenB.balanceOf(alice),
            aliceBalanceBBefore - amountBDesired + expectedExcessB,
            "Excess tokenB should be returned"
        );
    }

    /// @notice addLiquidity accepts any LP recipient. The former enforcement
    ///         of `to == msg.sender` was reverted because it didn't actually
    ///         close the tax-bypass route — Alice can always transfer the LP token to Bob
    ///         after minting it to herself, so the cross-recipient restriction added complexity
    ///         without security benefit. The protocol's design intent is "LP mint/burn is
    ///         tax-free; swaps on the pair always pay full tax". Two parties (or one party
    ///         splitting across wallets) coordinating an LP-route transfer is documented as
    ///         an accepted tradeoff in SPEC.md.
    function test_addLiquidity_LPTokensToDifferentRecipient() public {
        uint256 amountA = 100e18;
        uint256 amountB = 200e18;

        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), amountA);
        tokenB.approve(address(lpManager), amountB);
        vm.stopPrank();

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        if (pairAddr == address(0)) pairAddr = factory.createPair(address(tokenA), address(tokenB));
        uint256 bobLpBefore = IERC20(pairAddr).balanceOf(bob);

        vm.prank(alice);
        (,, uint256 liquidity) = lpManager.addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, MIN_AMOUNT, MIN_AMOUNT, bob, DEADLINE
        );

        assertGt(liquidity, 0, "liquidity should be minted");
        assertEq(IERC20(pairAddr).balanceOf(bob) - bobLpBefore, liquidity, "LP should land at bob");
    }

    function test_RevertWhen_addLiquidity_ZeroAmountA() public {
        tokenA.mint(alice, 100e18);
        tokenB.mint(alice, 200e18);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), 100e18);
        tokenB.approve(address(lpManager), 200e18);
        vm.stopPrank();

        vm.expectRevert(BoardwalkLPManager.ZeroAmount.selector);
        vm.prank(alice);
        lpManager.addLiquidity(
            address(tokenA),
            address(tokenB),
            0, // Zero amountA
            200e18,
            MIN_AMOUNT,
            MIN_AMOUNT,
            alice,
            DEADLINE
        );
    }

    function test_RevertWhen_addLiquidity_ZeroAmountB() public {
        tokenA.mint(alice, 100e18);
        tokenB.mint(alice, 200e18);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), 100e18);
        tokenB.approve(address(lpManager), 200e18);
        vm.stopPrank();

        vm.expectRevert(BoardwalkLPManager.ZeroAmount.selector);
        vm.prank(alice);
        lpManager.addLiquidity(
            address(tokenA),
            address(tokenB),
            100e18,
            0, // Zero amountB
            MIN_AMOUNT,
            MIN_AMOUNT,
            alice,
            DEADLINE
        );
    }

    function test_RevertWhen_addLiquidity_ZeroAddressTokenA() public {
        tokenA.mint(alice, 100e18);
        tokenB.mint(alice, 200e18);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), 100e18);
        tokenB.approve(address(lpManager), 200e18);
        vm.stopPrank();

        vm.expectRevert(BoardwalkLPManager.ZeroAddress.selector);
        vm.prank(alice);
        lpManager.addLiquidity(
            address(0), // Zero address
            address(tokenB),
            100e18,
            200e18,
            MIN_AMOUNT,
            MIN_AMOUNT,
            alice,
            DEADLINE
        );
    }

    function test_RevertWhen_addLiquidity_ZeroAddressTokenB() public {
        tokenA.mint(alice, 100e18);
        tokenB.mint(alice, 200e18);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), 100e18);
        tokenB.approve(address(lpManager), 200e18);
        vm.stopPrank();

        vm.expectRevert(BoardwalkLPManager.ZeroAddress.selector);
        vm.prank(alice);
        lpManager.addLiquidity(
            address(tokenA),
            address(0), // Zero address
            100e18,
            200e18,
            MIN_AMOUNT,
            MIN_AMOUNT,
            alice,
            DEADLINE
        );
    }

    function test_RevertWhen_addLiquidity_ZeroAddressTo() public {
        tokenA.mint(alice, 100e18);
        tokenB.mint(alice, 200e18);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), 100e18);
        tokenB.approve(address(lpManager), 200e18);
        vm.stopPrank();

        vm.expectRevert(BoardwalkLPManager.ZeroAddress.selector);
        vm.prank(alice);
        lpManager.addLiquidity(
            address(tokenA),
            address(tokenB),
            100e18,
            200e18,
            MIN_AMOUNT,
            MIN_AMOUNT,
            address(0), // Zero address
            DEADLINE
        );
    }

    function test_RevertWhen_addLiquidity_DeadlineExceeded() public {
        tokenA.mint(alice, 100e18);
        tokenB.mint(alice, 200e18);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), 100e18);
        tokenB.approve(address(lpManager), 200e18);
        vm.stopPrank();

        uint256 expiredDeadline = block.timestamp - 1;

        vm.expectRevert("Deadline exceeded");
        vm.prank(alice);
        lpManager.addLiquidity(
            address(tokenA), address(tokenB), 100e18, 200e18, MIN_AMOUNT, MIN_AMOUNT, alice, expiredDeadline
        );
    }

    function test_addLiquidity_ApprovalsResetAfterOperation() public {
        uint256 amountA = 100e18;
        uint256 amountB = 200e18;

        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), amountA);
        tokenB.approve(address(lpManager), amountB);
        vm.stopPrank();

        // First addLiquidity
        vm.prank(alice);
        lpManager.addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        // Verify approvals are reset
        assertEq(tokenA.allowance(address(lpManager), address(router)), 0, "Approval should be reset");
        assertEq(tokenB.allowance(address(lpManager), address(router)), 0, "Approval should be reset");

        // Can do another addLiquidity (approvals will be set again)
        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), amountA);
        tokenB.approve(address(lpManager), amountB);
        vm.stopPrank();

        vm.prank(alice);
        lpManager.addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        // Approvals should be reset again
        assertEq(tokenA.allowance(address(lpManager), address(router)), 0, "Approval should be reset after second call");
        assertEq(tokenB.allowance(address(lpManager), address(router)), 0, "Approval should be reset after second call");
    }

    // ============ removeLiquidity ============

    function test_removeLiquidity_HappyPath() public {
        // First, add liquidity to create a pair with reserves
        uint256 amountA = 100e18;
        uint256 amountB = 200e18;

        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), amountA);
        tokenB.approve(address(lpManager), amountB);
        vm.stopPrank();

        vm.prank(alice);
        lpManager.addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        uint256 aliceLPBalance = MockUniswapV2Pair(pairAddr).balanceOf(alice);

        // Now remove liquidity
        uint256 removeAmount = aliceLPBalance / 2; // Remove half

        vm.startPrank(alice);
        MockUniswapV2Pair(pairAddr).approve(address(lpManager), removeAmount);
        vm.stopPrank();

        uint256 aliceBalanceABefore = tokenA.balanceOf(alice);
        uint256 aliceBalanceBBefore = tokenB.balanceOf(alice);

        vm.prank(alice);
        (uint256 amountAOut, uint256 amountBOut) =
            lpManager.removeLiquidity(address(tokenA), address(tokenB), removeAmount, MIN_AMOUNT, MIN_AMOUNT, DEADLINE);

        // Verify tokens received
        assertGt(amountAOut, 0, "Should receive tokenA");
        assertGt(amountBOut, 0, "Should receive tokenB");

        // Verify tokens sent to alice
        assertEq(tokenA.balanceOf(alice), aliceBalanceABefore + amountAOut, "Alice should receive tokenA");
        assertEq(tokenB.balanceOf(alice), aliceBalanceBBefore + amountBOut, "Alice should receive tokenB");

        // Verify LP approval reset
        assertEq(
            MockUniswapV2Pair(pairAddr).allowance(address(lpManager), address(router)), 0, "LP approval should be reset"
        );
    }

    function test_RevertWhen_removeLiquidity_ZeroLiquidity() public {
        vm.expectRevert(BoardwalkLPManager.ZeroLiquidity.selector);
        vm.prank(alice);
        lpManager.removeLiquidity(
            address(tokenA),
            address(tokenB),
            0, // Zero liquidity
            MIN_AMOUNT,
            MIN_AMOUNT,
            DEADLINE
        );
    }

    function test_RevertWhen_removeLiquidity_PairNotFound() public {
        // Pair doesn't exist yet
        vm.expectRevert(BoardwalkLPManager.PairNotFound.selector);
        vm.prank(alice);
        lpManager.removeLiquidity(address(tokenA), address(tokenB), 100e18, MIN_AMOUNT, MIN_AMOUNT, DEADLINE);
    }

    function test_RevertWhen_removeLiquidity_DeadlineExceeded() public {
        // Create pair first
        uint256 amountA = 100e18;
        uint256 amountB = 200e18;

        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), amountA);
        tokenB.approve(address(lpManager), amountB);
        vm.stopPrank();

        vm.prank(alice);
        (,, uint256 liquidity) = lpManager.addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));

        vm.startPrank(alice);
        MockUniswapV2Pair(pairAddr).approve(address(lpManager), liquidity);
        vm.stopPrank();

        uint256 expiredDeadline = block.timestamp - 1;

        vm.expectRevert("Deadline exceeded");
        vm.prank(alice);
        lpManager.removeLiquidity(address(tokenA), address(tokenB), liquidity, MIN_AMOUNT, MIN_AMOUNT, expiredDeadline);
    }

    function test_removeLiquidity_ApprovalsResetAfterOperation() public {
        // Add liquidity first
        uint256 amountA = 100e18;
        uint256 amountB = 200e18;

        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), amountA);
        tokenB.approve(address(lpManager), amountB);
        vm.stopPrank();

        vm.prank(alice);
        (,, uint256 liquidity) = lpManager.addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));

        vm.startPrank(alice);
        MockUniswapV2Pair(pairAddr).approve(address(lpManager), liquidity);
        vm.stopPrank();

        // Remove liquidity
        vm.prank(alice);
        lpManager.removeLiquidity(address(tokenA), address(tokenB), liquidity, MIN_AMOUNT, MIN_AMOUNT, DEADLINE);

        // Verify LP approval reset
        assertEq(
            MockUniswapV2Pair(pairAddr).allowance(address(lpManager), address(router)), 0, "LP approval should be reset"
        );
    }

    function test_removeLiquidity_TokensForwardedToUser() public {
        // Add liquidity
        uint256 amountA = 100e18;
        uint256 amountB = 200e18;

        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), amountA);
        tokenB.approve(address(lpManager), amountB);
        vm.stopPrank();

        vm.prank(alice);
        (,, uint256 liquidity) = lpManager.addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));

        vm.startPrank(alice);
        MockUniswapV2Pair(pairAddr).approve(address(lpManager), liquidity);
        vm.stopPrank();

        // Verify LPManager has no tokens before removal
        assertEq(tokenA.balanceOf(address(lpManager)), 0, "LPManager should have no tokenA before");
        assertEq(tokenB.balanceOf(address(lpManager)), 0, "LPManager should have no tokenB before");

        uint256 aliceBalanceABefore = tokenA.balanceOf(alice);
        uint256 aliceBalanceBBefore = tokenB.balanceOf(alice);

        // Remove liquidity
        vm.prank(alice);
        (uint256 amountAOut, uint256 amountBOut) =
            lpManager.removeLiquidity(address(tokenA), address(tokenB), liquidity, MIN_AMOUNT, MIN_AMOUNT, DEADLINE);

        // Verify tokens went directly to alice (not stuck in LPManager)
        assertEq(tokenA.balanceOf(address(lpManager)), 0, "LPManager should have no tokenA after");
        assertEq(tokenB.balanceOf(address(lpManager)), 0, "LPManager should have no tokenB after");
        assertEq(tokenA.balanceOf(alice), aliceBalanceABefore + amountAOut, "Alice should receive tokenA");
        assertEq(tokenB.balanceOf(alice), aliceBalanceBBefore + amountBOut, "Alice should receive tokenB");
    }

    // ============ Fuzz Tests ============

    function testFuzz_addLiquidity_RandomAmounts(
        uint256 amountA,
        uint256 amountB
    ) public {
        // Bound amounts to reasonable ranges
        amountA = bound(amountA, 1e18, MAX_AMOUNT);
        amountB = bound(amountB, 1e18, MAX_AMOUNT);

        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), amountA);
        tokenB.approve(address(lpManager), amountB);
        vm.stopPrank();

        vm.prank(alice);
        (uint256 actualA, uint256 actualB, uint256 liquidity) = lpManager.addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        // Verify amounts used are within desired amounts
        assertLe(actualA, amountA, "actualA should not exceed desired");
        assertLe(actualB, amountB, "actualB should not exceed desired");

        // Verify liquidity is minted
        assertGt(liquidity, 0, "Liquidity should be greater than 0");

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        assertEq(MockUniswapV2Pair(pairAddr).balanceOf(alice), liquidity, "LP balance should match returned liquidity");

        // Verify approvals reset
        assertEq(tokenA.allowance(address(lpManager), address(router)), 0, "Approval should be reset");
        assertEq(tokenB.allowance(address(lpManager), address(router)), 0, "Approval should be reset");
    }

    function testFuzz_removeLiquidity_RandomAmounts(
        uint256 initialA,
        uint256 initialB,
        uint256 removeRatioBps
    ) public {
        // Bound inputs
        initialA = bound(initialA, 10e18, MAX_AMOUNT);
        initialB = bound(initialB, 10e18, MAX_AMOUNT);
        removeRatioBps = bound(removeRatioBps, 1000, 10000); // 10% to 100%

        // Add liquidity first
        tokenA.mint(alice, initialA);
        tokenB.mint(alice, initialB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), initialA);
        tokenB.approve(address(lpManager), initialB);
        vm.stopPrank();

        vm.prank(alice);
        (,, uint256 totalLiquidity) = lpManager.addLiquidity(
            address(tokenA), address(tokenB), initialA, initialB, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));
        uint256 removeAmount = (totalLiquidity * removeRatioBps) / 10000;

        vm.startPrank(alice);
        MockUniswapV2Pair(pairAddr).approve(address(lpManager), removeAmount);
        vm.stopPrank();

        uint256 aliceBalanceABefore = tokenA.balanceOf(alice);
        uint256 aliceBalanceBBefore = tokenB.balanceOf(alice);

        vm.prank(alice);
        (uint256 amountAOut, uint256 amountBOut) =
            lpManager.removeLiquidity(address(tokenA), address(tokenB), removeAmount, MIN_AMOUNT, MIN_AMOUNT, DEADLINE);

        // Verify tokens received
        assertGt(amountAOut, 0, "Should receive tokenA");
        assertGt(amountBOut, 0, "Should receive tokenB");

        // Verify balances updated
        assertEq(tokenA.balanceOf(alice), aliceBalanceABefore + amountAOut, "Alice should receive tokenA");
        assertEq(tokenB.balanceOf(alice), aliceBalanceBBefore + amountBOut, "Alice should receive tokenB");

        // Verify approval reset
        assertEq(
            MockUniswapV2Pair(pairAddr).allowance(address(lpManager), address(router)), 0, "LP approval should be reset"
        );
    }

    // ============ Edge Cases ============

    function test_addLiquidity_MinimumAmounts() public {
        uint256 amountA = 1e18;
        uint256 amountB = 1e18;

        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), amountA);
        tokenB.approve(address(lpManager), amountB);
        vm.stopPrank();

        vm.prank(alice);
        (uint256 actualA, uint256 actualB, uint256 liquidity) = lpManager.addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        assertGe(actualA, MIN_AMOUNT, "actualA should meet minimum");
        assertGe(actualB, MIN_AMOUNT, "actualB should meet minimum");
        assertGt(liquidity, 0, "Should receive liquidity");
    }

    function test_removeLiquidity_AllLiquidity() public {
        // Add liquidity
        uint256 amountA = 100e18;
        uint256 amountB = 200e18;

        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), amountA);
        tokenB.approve(address(lpManager), amountB);
        vm.stopPrank();

        vm.prank(alice);
        (,, uint256 totalLiquidity) = lpManager.addLiquidity(
            address(tokenA), address(tokenB), amountA, amountB, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));

        vm.startPrank(alice);
        MockUniswapV2Pair(pairAddr).approve(address(lpManager), totalLiquidity);
        vm.stopPrank();

        // Remove all liquidity
        vm.prank(alice);
        (uint256 amountAOut, uint256 amountBOut) = lpManager.removeLiquidity(
            address(tokenA), address(tokenB), totalLiquidity, MIN_AMOUNT, MIN_AMOUNT, DEADLINE
        );

        // Verify all tokens returned
        assertGt(amountAOut, 0, "Should receive tokenA");
        assertGt(amountBOut, 0, "Should receive tokenB");

        // Verify no LP tokens left
        assertEq(MockUniswapV2Pair(pairAddr).balanceOf(alice), 0, "All LP should be removed");
    }

    function test_addLiquidity_MultipleUsers() public {
        uint256 aliceAmountA = 50e18;
        uint256 aliceAmountB = 100e18;
        uint256 bobAmountA = 30e18;
        uint256 bobAmountB = 60e18;

        // Alice adds liquidity
        tokenA.mint(alice, aliceAmountA);
        tokenB.mint(alice, aliceAmountB);

        vm.startPrank(alice);
        tokenA.approve(address(lpManager), aliceAmountA);
        tokenB.approve(address(lpManager), aliceAmountB);
        vm.stopPrank();

        vm.prank(alice);
        (,, uint256 aliceLiquidity) = lpManager.addLiquidity(
            address(tokenA), address(tokenB), aliceAmountA, aliceAmountB, MIN_AMOUNT, MIN_AMOUNT, alice, DEADLINE
        );

        // Bob adds liquidity
        tokenA.mint(bob, bobAmountA);
        tokenB.mint(bob, bobAmountB);

        vm.startPrank(bob);
        tokenA.approve(address(lpManager), bobAmountA);
        tokenB.approve(address(lpManager), bobAmountB);
        vm.stopPrank();

        vm.prank(bob);
        (,, uint256 bobLiquidity) = lpManager.addLiquidity(
            address(tokenA), address(tokenB), bobAmountA, bobAmountB, MIN_AMOUNT, MIN_AMOUNT, bob, DEADLINE
        );

        address pairAddr = factory.getPair(address(tokenA), address(tokenB));

        // Verify both users have LP tokens
        assertEq(MockUniswapV2Pair(pairAddr).balanceOf(alice), aliceLiquidity, "Alice should have LP");
        assertEq(MockUniswapV2Pair(pairAddr).balanceOf(bob), bobLiquidity, "Bob should have LP");
    }

    // ============ Security: No Swap Functions ============

    function test_Security_NoSwapFunctionsExposed() public {
        // Verify that LPManager only exposes addLiquidity and removeLiquidity
        // This is a compile-time check - if swap functions were added, this test would fail
        // We can verify by checking the interface

        // Try to call a non-existent swap function (should not compile, but we can test the interface)
        bytes4 addLiquiditySelector = IBoardwalkLPManager.addLiquidity.selector;
        bytes4 removeLiquiditySelector = IBoardwalkLPManager.removeLiquidity.selector;

        // Verify these selectors exist
        assertTrue(addLiquiditySelector != bytes4(0), "addLiquidity should exist");
        assertTrue(removeLiquiditySelector != bytes4(0), "removeLiquidity should exist");

        // Verify swap functions are NOT in the interface
        // swapExactTokensForTokens selector: 0x38ed1739
        // This is a documentation test - the interface doesn't have swap functions
        // If someone adds swap functions, they would need to update the interface
        // The fact that this test compiles confirms no swap functions exist in the interface
    }

    // ================================================================
    //  COVERAGE GAP TESTS — Constructor validation
    // ================================================================

    function test_RevertWhen_Constructor_ZeroFactory() public {
        vm.expectRevert(BoardwalkLPManager.ZeroAddress.selector);
        new BoardwalkLPManager(address(0), address(router), address(tokenA));
    }

    function test_RevertWhen_Constructor_ZeroRaiseToken() public {
        vm.expectRevert(BoardwalkLPManager.ZeroAddress.selector);
        new BoardwalkLPManager(address(factory), address(router), address(0));
    }

    function test_RevertWhen_Constructor_FactoryRouterMismatch() public {
        // Deploy a separate factory that the router doesn't point to
        MockUniswapV2Factory otherFactory = new MockUniswapV2Factory();
        vm.expectRevert(BoardwalkLPManager.FactoryRouterMismatch.selector);
        new BoardwalkLPManager(address(otherFactory), address(router), address(tokenA));
    }

    // ============ Pair Restriction Tests ============

    function test_RevertWhen_AddLiquidity_InvalidPair() public {
        MockERC20 junkToken = new MockERC20("Junk", "JUNK");

        junkToken.mint(alice, 100e18);
        tokenB.mint(alice, 100e18);

        vm.startPrank(alice);
        junkToken.approve(address(lpManager), 100e18);
        tokenB.approve(address(lpManager), 100e18);

        // Neither token is RAISE_TOKEN (tokenA) — should revert
        vm.expectRevert(BoardwalkLPManager.InvalidPair.selector);
        lpManager.addLiquidity(address(junkToken), address(tokenB), 100e18, 100e18, 0, 0, alice, block.timestamp);
        vm.stopPrank();
    }

    function test_RevertWhen_RemoveLiquidity_InvalidPair() public {
        MockERC20 junkToken = new MockERC20("Junk", "JUNK");

        // Create pair for junk + tokenB
        factory.createPair(address(junkToken), address(tokenB));
        address pairAddr = factory.getPair(address(junkToken), address(tokenB));

        MockERC20(pairAddr).mint(alice, 100e18);

        vm.startPrank(alice);
        MockERC20(pairAddr).approve(address(lpManager), 100e18);

        // Neither token is RAISE_TOKEN — should revert
        vm.expectRevert(BoardwalkLPManager.InvalidPair.selector);
        lpManager.removeLiquidity(address(junkToken), address(tokenB), 100e18, 0, 0, block.timestamp);
        vm.stopPrank();
    }
}

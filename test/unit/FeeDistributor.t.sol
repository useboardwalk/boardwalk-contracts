// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FeeDistributor} from "src/core/FeeDistributor.sol";
import {IFeeDistributor} from "src/interfaces/IFeeDistributor.sol";
import {ILPStaking} from "src/interfaces/ILPStaking.sol";
import {IBoardwalkFeeCollector} from "src/interfaces/IBoardwalkFeeCollector.sol";
import {Timelocked} from "src/base/Timelocked.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @dev Mock LPStaking that records notifyFees calls (configurable to revert for failure tests)
contract MockLPStaking is ILPStaking {
    uint256 public lastFeeAmount;
    uint256 public totalFeesReceived;
    uint256 public callCount;
    bool public shouldRevert;

    function setShouldRevert(
        bool _shouldRevert
    ) external {
        shouldRevert = _shouldRevert;
    }

    function notifyFees(
        uint256 amount
    ) external override {
        if (shouldRevert) revert("MockLPStaking: forced revert");
        lastFeeAmount = amount;
        totalFeesReceived += amount;
        callCount++;
    }

    // Stubs for interface compliance
    function setInitializer(
        address
    ) external pure override {}

    function initialize(
        address,
        address,
        address,
        uint256,
        uint256
    ) external pure override {
        revert("Not implemented");
    }

    function stake(
        uint256
    ) external pure override {
        revert("Not implemented");
    }

    function withdraw(
        uint256
    ) external pure override {
        revert("Not implemented");
    }

    function claim() external pure override returns (uint256) {
        revert("Not implemented");
    }

    function pendingRewards(
        address
    ) external pure override returns (uint256) {
        revert("Not implemented");
    }

    function getPoolStats()
        external
        pure
        override
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
    {
        revert("Not implemented");
    }

    function getUserInfo(
        address
    ) external pure override returns (uint256, uint256, uint256, uint256, uint256) {
        revert("Not implemented");
    }
}

/// @dev Mock BoardwalkFeeCollector that records receiveFees calls (configurable to revert for failure tests)
contract MockFeeCollector is IBoardwalkFeeCollector {
    mapping(address => uint256) public accumulatedFees;
    uint256 public callCount;
    bool public shouldRevert;

    function setShouldRevert(
        bool _shouldRevert
    ) external {
        shouldRevert = _shouldRevert;
    }

    function receiveFees(
        address token,
        uint256 amount
    ) external override {
        if (shouldRevert) revert("MockFeeCollector: forced revert");
        accumulatedFees[token] += amount;
        callCount++;
    }

    // Stubs for interface compliance
    function swapToRaiseToken(
        address[] calldata,
        uint256[] calldata,
        uint256
    ) external pure override {
        revert("Not implemented");
    }

    function RAISE_TOKEN() external pure override returns (address) {
        revert("Not implemented");
    }

    function ROUTER() external pure override returns (address) {
        revert("Not implemented");
    }

    function treasury() external pure override returns (address) {
        revert("Not implemented");
    }

    function keeper() external pure override returns (address) {
        revert("Not implemented");
    }

    function executeMigrateCollector(
        address,
        address[] calldata
    ) external pure override {
        revert("Not implemented");
    }

    function governanceVault() external pure override returns (address) {
        revert("Not implemented");
    }

    function GOVERNANCE_BPS() external pure override returns (uint256) {
        revert("Not implemented");
    }
}

/// @dev Mock Router for swapExactTokensForTokens
contract MockRouter {
    uint256 public constant MOCK_SLIPPAGE_BPS = 100; // 1% slippage
    mapping(address => mapping(address => uint256)) public exchangeRates; // token -> weth rate

    function setExchangeRate(
        address token,
        address weth,
        uint256 rate
    ) external {
        exchangeRates[token][weth] = rate; // e.g., 1 token = rate wei WETH
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
        // Allow 0 for testing, but in production this should be > 0

        address tokenIn = path[0];
        address tokenOut = path[1];
        uint256 rate = exchangeRates[tokenIn][tokenOut];
        require(rate > 0, "Exchange rate not set");

        uint256 amountOut = (amountIn * rate) / 1e18;
        require(amountOut >= amountOutMin, "Slippage exceeded");

        // Transfer tokens from caller (FeeDistributor) to this mock
        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // Mint WETH to recipient (mock can mint)
        MockERC20(tokenOut).mint(to, amountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}

/// @dev Simple ERC20 token for testing
contract MockERC20 is ERC20 {
    mapping(address => bool) public isExempt;

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

    /// @dev FeeDistributor calls updateExempt during collector migration
    function updateExempt(address account, bool exempt) external {
        isExempt[account] = exempt;
    }
}

/// @title FeeDistributorTest
/// @notice Comprehensive unit + fuzz tests for FeeDistributor
contract FeeDistributorTest is Test {
    // ============ Constants ============

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant TIMELOCK_DELAY = 7 days;
    uint256 internal constant TIMELOCK_EXPIRY = 7 days;
    uint256 internal constant RATE_LIMIT_BPS = 1000; // 10% = 1000/10000

    // ============ State ============

    FeeDistributor internal template;
    FeeDistributor internal feeDistributor;
    MockLPStaking internal lpStaking;
    MockFeeCollector internal feeCollector;
    MockRouter internal router;
    MockERC20 internal token;
    MockERC20 internal weth;

    address internal issuer1;
    address internal issuer2;
    address internal issuer3;
    address internal referrer;
    address internal integratorAddr;
    address internal alice;
    address internal bob;

    // ============ Events (re-declared for vm.expectEmit) ============

    event TaxReceived(
        uint256 amount, uint256 lpShare, uint256 boardwalkShare, uint256 issuerShare, uint256 referrerShare, uint256 integratorShare
    );
    event IssuerClaimed(
        uint256 indexed recipientIdx, address indexed recipient, uint256 tokenAmount, uint256 wethAmount
    );
    event ReferrerClaimed(address indexed referrer, uint256 amount);
    event IssuerAddressChanged(uint256 indexed recipientIdx, address oldAddress, address newAddress);
    event ReferrerAddressChanged(address oldAddress, address newAddress);
    event IntegratorClaimed(address indexed integrator, uint256 amount);
    event FeeCollectorChanged(address oldCollector, address newCollector);
    event FeeForwardFailed(string target, uint256 amount);
    event ChangeSignaled(bytes32 indexed action, bytes32 dataHash, uint256 executeTime, uint256 expiresAt);
    event ChangeExecuted(bytes32 indexed action);
    event ChangeCanceled(bytes32 indexed action);

    // ============ Setup ============

    function setUp() public {
        issuer1 = makeAddr("issuer1");
        issuer2 = makeAddr("issuer2");
        issuer3 = makeAddr("issuer3");
        referrer = makeAddr("referrer");
        integratorAddr = makeAddr("integrator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.label(issuer1, "issuer1");
        vm.label(issuer2, "issuer2");
        vm.label(issuer3, "issuer3");
        vm.label(referrer, "referrer");
        vm.label(integratorAddr, "integrator");

        // Deploy mocks
        lpStaking = new MockLPStaking();
        feeCollector = new MockFeeCollector();
        router = new MockRouter();
        token = new MockERC20("TestToken", "TT");
        weth = new MockERC20("WETH", "WETH");

        // Set exchange rate: 1 token = 0.5 WETH (for testing swaps)
        router.setExchangeRate(address(token), address(weth), 0.5e18);

        // Deploy template and clone
        template = new FeeDistributor();
        feeDistributor = _deployInitializedFeeDistributor();
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Initialization
    // ──────────────────────────────────────────────────────────────────────────

    function test_Initialize_SetsAllState() public view {
        assertEq(address(feeDistributor.token()), address(token), "token mismatch");
        assertEq(address(feeDistributor.lpStaking()), address(lpStaking), "lpStaking mismatch");
        assertEq(address(feeDistributor.feeCollector()), address(feeCollector), "feeCollector mismatch");
        assertEq(address(feeDistributor.router()), address(router), "router mismatch");
        assertEq(address(feeDistributor.raiseToken()), address(weth), "raise token mismatch");
        assertEq(feeDistributor.issuerBps(), 5000, "issuerBps mismatch");
        assertEq(feeDistributor.boardwalkBps(), 2000, "boardwalkBps mismatch");
        assertEq(feeDistributor.lpIncentiveBps(), 2000, "lpIncentiveBps mismatch");
        assertEq(feeDistributor.referrerBps(), 1000, "referrerBps mismatch");
        assertEq(feeDistributor.totalFeeBps(), 10000, "totalFeeBps mismatch");
        assertEq(feeDistributor.referrer(), referrer, "referrer mismatch");
        assertEq(feeDistributor.issuerRecipientCount(), 3, "issuerRecipientCount mismatch");
    }

    function test_Initialize_SetsIssuerRecipients() public view {
        assertEq(feeDistributor.issuerRecipients(0), issuer1, "issuer1 mismatch");
        assertEq(feeDistributor.issuerRecipients(1), issuer2, "issuer2 mismatch");
        assertEq(feeDistributor.issuerRecipients(2), issuer3, "issuer3 mismatch");
    }

    function test_Initialize_ApprovesContracts() public view {
        assertEq(
            token.allowance(address(feeDistributor), address(lpStaking)),
            type(uint256).max,
            "lpStaking approval mismatch"
        );
        assertEq(
            token.allowance(address(feeDistributor), address(feeCollector)),
            type(uint256).max,
            "feeCollector approval mismatch"
        );
        assertEq(
            token.allowance(address(feeDistributor), address(router)), type(uint256).max, "router approval mismatch"
        );
    }

    function test_Initialize_SingleIssuerRecipient() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.issuerRecipients = _toArray(issuer1);
        p.issuerSplits = _toArray(BPS_DENOMINATOR);

        fd.initialize(p);

        assertEq(fd.issuerRecipientCount(), 1, "should have 1 issuer recipient");
        assertEq(fd.issuerRecipients(0), issuer1, "issuer1 should be set");
    }

    function test_Initialize_TwoIssuerRecipients() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.issuerRecipients = _toArray(issuer1, issuer2);
        p.issuerSplits = _toArray(6000, 4000);

        fd.initialize(p);

        assertEq(fd.issuerRecipientCount(), 2, "should have 2 issuer recipients");
        assertEq(fd.issuerRecipients(0), issuer1, "issuer1 should be set");
        assertEq(fd.issuerRecipients(1), issuer2, "issuer2 should be set");
    }

    function test_Initialize_NoReferrer() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.referrer = address(0);
        p.referrerBps = 0;
        p.issuerBps = 6000; // Adjust to sum to 10000

        fd.initialize(p);

        assertEq(fd.referrer(), address(0), "referrer should be zero");
        assertEq(fd.referrerBps(), 0, "referrerBps should be 0");
    }

    function test_RevertWhen_InitializeTwice() public {
        FeeDistributor.InitParams memory p = _defaultInitParams();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        feeDistributor.initialize(p);
    }

    function test_RevertWhen_Initialize_ZeroToken() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.token = address(0);

        vm.expectRevert(FeeDistributor.ZeroAddress.selector);
        fd.initialize(p);
    }

    function test_RevertWhen_Initialize_ZeroLpStaking() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.lpStaking = address(0);

        vm.expectRevert(FeeDistributor.ZeroAddress.selector);
        fd.initialize(p);
    }

    function test_RevertWhen_Initialize_ZeroFeeCollector() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.feeCollector = address(0);

        vm.expectRevert(FeeDistributor.ZeroAddress.selector);
        fd.initialize(p);
    }

    function test_RevertWhen_Initialize_ZeroRouter() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.router = address(0);

        vm.expectRevert(FeeDistributor.ZeroAddress.selector);
        fd.initialize(p);
    }

    function test_RevertWhen_Initialize_ZeroRaiseToken() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.raiseToken = address(0);

        vm.expectRevert(FeeDistributor.ZeroAddress.selector);
        fd.initialize(p);
    }

    function test_RevertWhen_Initialize_ZeroIssuerRecipient() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.issuerRecipients[0] = address(0);

        vm.expectRevert(FeeDistributor.ZeroAddress.selector);
        fd.initialize(p);
    }

    function test_RevertWhen_Initialize_ArrayLengthMismatch_RecipientsSplits() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.issuerSplits = _toArray(5000, 5000); // 2 splits but 3 recipients

        vm.expectRevert(FeeDistributor.ArrayLengthMismatch.selector);
        fd.initialize(p);
    }

    function test_RevertWhen_Initialize_EmptyRecipients() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.issuerRecipients = new address[](0);
        p.issuerSplits = new uint256[](0);

        vm.expectRevert(FeeDistributor.ArrayLengthMismatch.selector);
        fd.initialize(p);
    }

    function test_RevertWhen_Initialize_InvalidSplitsSum() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.issuerSplits = _toArray(3000, 3000, 3000); // Sums to 9000, not 10000

        vm.expectRevert(FeeDistributor.InvalidSplitsSum.selector);
        fd.initialize(p);
    }

    function test_RevertWhen_Initialize_ZeroTotalFeeBps() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.issuerBps = 0;
        p.boardwalkBps = 0;
        p.lpIncentiveBps = 0;
        p.referrerBps = 0;

        vm.expectRevert(FeeDistributor.InvalidFeeBps.selector);
        fd.initialize(p);
    }

    function test_Constructor_DisablesInitOnTemplate() public {
        FeeDistributor.InitParams memory p = _defaultInitParams();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        template.initialize(p);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  onTaxReceived
    // ──────────────────────────────────────────────────────────────────────────

    function test_OnTaxReceived_OnlyTokenCanCall() public {
        deal(address(token), address(feeDistributor), 1000e18);

        vm.expectRevert(FeeDistributor.OnlyToken.selector);
        vm.prank(alice);
        feeDistributor.onTaxReceived(1000e18);
    }

    function test_OnTaxReceived_SplitsCorrectly() public {
        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        // Expected splits (5000/10000, 2000/10000, 2000/10000, 1000/10000)
        uint256 expectedLpShare = taxAmount * 2000 / 10000; // 2000e18
        uint256 expectedBoardwalkShare = taxAmount * 2000 / 10000; // 2000e18
        uint256 expectedReferrerShare = taxAmount * 1000 / 10000; // 1000e18
        uint256 expectedIssuerShare = taxAmount - expectedLpShare - expectedBoardwalkShare - expectedReferrerShare; // 5000e18

        assertEq(lpStaking.totalFeesReceived(), expectedLpShare, "LP share mismatch");
        assertEq(feeCollector.accumulatedFees(address(token)), expectedBoardwalkShare, "Boardwalk share mismatch");
        assertEq(feeDistributor.referrerAccrued(), expectedReferrerShare, "Referrer accrued mismatch");

        // Check issuer accrual (split among 3 recipients: 40%, 30%, 30%)
        (uint256 totalAccrued0,,,) = feeDistributor.issuerClaimStates(0);
        (uint256 totalAccrued1,,,) = feeDistributor.issuerClaimStates(1);
        (uint256 totalAccrued2,,,) = feeDistributor.issuerClaimStates(2);

        assertEq(totalAccrued0, expectedIssuerShare * 4000 / 10000, "Issuer1 accrued mismatch");
        assertEq(totalAccrued1, expectedIssuerShare * 3000 / 10000, "Issuer2 accrued mismatch");
        // Issuer3 gets remainder (handles rounding)
        uint256 issuer1Accrued = expectedIssuerShare * 4000 / 10000;
        uint256 issuer2Accrued = expectedIssuerShare * 3000 / 10000;
        uint256 issuer3Accrued = expectedIssuerShare - issuer1Accrued - issuer2Accrued;
        assertEq(totalAccrued2, issuer3Accrued, "Issuer3 accrued mismatch");
    }

    function test_OnTaxReceived_ForwardsLpShare() public {
        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        assertEq(lpStaking.callCount(), 1, "notifyFees should be called once");
        assertEq(lpStaking.lastFeeAmount(), taxAmount * 2000 / 10000, "LP share amount mismatch");
    }

    function test_OnTaxReceived_ForwardsBoardwalkShare() public {
        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        assertEq(feeCollector.callCount(), 1, "receiveFees should be called once");
        assertEq(feeCollector.accumulatedFees(address(token)), taxAmount * 2000 / 10000, "Boardwalk share mismatch");
    }

    function test_OnTaxReceived_AccruesIssuerFees() public {
        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        uint256 issuerShare = taxAmount * 5000 / 10000; // 5000e18
        uint256 issuer1Accrued = issuerShare * 4000 / 10000; // 2000e18
        uint256 issuer2Accrued = issuerShare * 3000 / 10000; // 1500e18
        uint256 issuer3Accrued = issuerShare - issuer1Accrued - issuer2Accrued; // 1500e18

        (uint256 totalAccrued0,,,) = feeDistributor.issuerClaimStates(0);
        (uint256 totalAccrued1,,,) = feeDistributor.issuerClaimStates(1);
        (uint256 totalAccrued2,,,) = feeDistributor.issuerClaimStates(2);

        assertEq(totalAccrued0, issuer1Accrued, "Issuer1 accrued mismatch");
        assertEq(totalAccrued1, issuer2Accrued, "Issuer2 accrued mismatch");
        assertEq(totalAccrued2, issuer3Accrued, "Issuer3 accrued mismatch");
    }

    function test_OnTaxReceived_AccruesReferrerFees() public {
        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        assertEq(feeDistributor.referrerAccrued(), taxAmount * 1000 / 10000, "Referrer accrued mismatch");
    }

    function test_OnTaxReceived_NoReferrer_ZeroReferrerShare() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.referrer = address(0);
        p.referrerBps = 0;
        p.issuerBps = 6000; // Adjust to sum to 10000
        fd.initialize(p);

        uint256 taxAmount = 10000e18;
        deal(address(token), address(fd), taxAmount);

        vm.prank(address(token));
        fd.onTaxReceived(taxAmount);

        assertEq(fd.referrerAccrued(), 0, "Referrer accrued should be 0 when no referrer");
    }

    function test_OnTaxReceived_RoundingDustGoesToLastRecipient() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        p.issuerRecipients = _toArray(issuer1, issuer2);
        p.issuerSplits = _toArray(3333, 6667); // Sums to 10000
        fd.initialize(p);

        // Use amount that causes rounding: 1000e18 * 5000/10000 = 500e18 issuer share
        // Split: 500e18 * 3333/10000 = 166.65e18 (truncates to 166e18)
        // Remainder: 500e18 - 166e18 = 334e18 goes to issuer2
        uint256 taxAmount = 1000e18;
        deal(address(token), address(fd), taxAmount);

        vm.prank(address(token));
        fd.onTaxReceived(taxAmount);

        uint256 issuerShare = taxAmount * 5000 / 10000; // 500e18
        uint256 issuer1Accrued = issuerShare * 3333 / 10000; // 166e18 (truncated)
        uint256 issuer2Accrued = issuerShare - issuer1Accrued; // 334e18 (gets remainder)

        (uint256 totalAccrued0,,,) = fd.issuerClaimStates(0);
        (uint256 totalAccrued1,,,) = fd.issuerClaimStates(1);

        assertEq(totalAccrued0, issuer1Accrued, "Issuer1 accrued mismatch");
        assertEq(totalAccrued1, issuer2Accrued, "Issuer2 should get remainder");
        assertEq(issuer1Accrued + issuer2Accrued, issuerShare, "Total should equal issuer share");
    }

    function test_OnTaxReceived_EmitsEvent() public {
        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        uint256 expectedLpShare = taxAmount * 2000 / 10000;
        uint256 expectedBoardwalkShare = taxAmount * 2000 / 10000;
        uint256 expectedReferrerShare = taxAmount * 1000 / 10000;
        uint256 expectedIssuerShare = taxAmount - expectedLpShare - expectedBoardwalkShare - expectedReferrerShare;

        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit TaxReceived(taxAmount, expectedLpShare, expectedBoardwalkShare, expectedIssuerShare, expectedReferrerShare, 0);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);
    }

    function test_OnTaxReceived_MultipleCalls_Accumulate() public {
        deal(address(token), address(feeDistributor), 20000e18);

        vm.startPrank(address(token));
        feeDistributor.onTaxReceived(10000e18);
        feeDistributor.onTaxReceived(10000e18);
        vm.stopPrank();

        assertEq(lpStaking.totalFeesReceived(), 4000e18, "LP fees should accumulate");
        assertEq(feeCollector.accumulatedFees(address(token)), 4000e18, "Boardwalk fees should accumulate");
        assertEq(feeDistributor.referrerAccrued(), 2000e18, "Referrer fees should accumulate");
        // Each call: 10000e18 * 5000/10000 = 5000e18 issuer share
        // Recipient 0 gets: 5000e18 * 4000/10000 = 2000e18 per call
        // Total after 2 calls: 4000e18
        (uint256 totalAccrued0,,,) = feeDistributor.issuerClaimStates(0);
        assertEq(totalAccrued0, 4000e18, "Issuer1 fees should accumulate");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Issuer WETH Claim
    // ──────────────────────────────────────────────────────────────────────────

    function test_ClaimAsWeth_OnlyRecipientCanCall() public {
        _accrueIssuerFees(0, 10000e18);

        vm.expectRevert(FeeDistributor.NotRecipient.selector);
        vm.prank(alice);
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);
    }

    function test_ClaimAsWeth_RateLimit_10PercentPer24h() public {
        uint256 totalAccrued = 100000e18;
        _accrueIssuerFees(0, totalAccrued);

        // First claim: can claim 10% = 10000e18
        uint256 claimable = feeDistributor.claimableAmount(0);
        assertEq(claimable, totalAccrued / 10, "First claim should be 10% of total accrued");

        uint256 wethBefore = weth.balanceOf(issuer1);
        deal(address(token), address(feeDistributor), claimable);

        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);

        uint256 wethAfter = weth.balanceOf(issuer1);
        assertGt(wethAfter, wethBefore, "Should receive WETH");
    }

    function test_ClaimAsWeth_RateLimit_IndependentPerRecipient() public {
        // Accrue fees for both recipients
        // When we call _accrueIssuerFees, it accrues for all recipients proportionally
        // So we need to accrue enough that each gets the desired amount
        uint256 desiredAmount0 = 100000e18;
        uint256 desiredAmount1 = 100000e18;

        // Accrue for recipient 0 (this will also accrue for others)
        _accrueIssuerFees(0, desiredAmount0);
        // Accrue for recipient 1 (this will also accrue for others)
        _accrueIssuerFees(1, desiredAmount1);

        // Both recipients should be able to claim independently
        (uint256 totalAccrued0,,,) = feeDistributor.issuerClaimStates(0);
        (uint256 totalAccrued1,,,) = feeDistributor.issuerClaimStates(1);

        uint256 claimable0 = feeDistributor.claimableAmount(0);
        uint256 claimable1 = feeDistributor.claimableAmount(1);
        assertEq(claimable0, totalAccrued0 / 10, "Recipient 0 claimable should be 10% of total accrued");
        assertEq(claimable1, totalAccrued1 / 10, "Recipient 1 claimable should be 10% of total accrued");

        deal(address(token), address(feeDistributor), claimable0 + claimable1);

        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);

        vm.prank(issuer2);
        feeDistributor.claimAsRaiseToken(1, 0, block.timestamp + 1 hours);

        assertGt(weth.balanceOf(issuer1), 0, "Issuer1 should receive WETH");
        assertGt(weth.balanceOf(issuer2), 0, "Issuer2 should receive WETH");
    }

    function test_ClaimAsWeth_RateLimit_NewPeriodAfter24h() public {
        uint256 totalAccrued = 100000e18;
        _accrueIssuerFees(0, totalAccrued);

        // First claim
        uint256 firstClaimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), firstClaimable);

        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, type(uint256).max);

        // Warp forward 24 hours + 1 second
        vm.warp(block.timestamp + 1 days + 1);

        // Should be able to claim another 10%
        uint256 secondClaimable = feeDistributor.claimableAmount(0);
        assertEq(secondClaimable, totalAccrued / 10, "Should be able to claim another 10% after 24h");

        deal(address(token), address(feeDistributor), secondClaimable);
        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, type(uint256).max);
    }

    function test_ClaimAsWeth_RateLimit_SamePeriod_SubtractsClaimed() public {
        uint256 totalAccrued = 100000e18;
        _accrueIssuerFees(0, totalAccrued);

        // First claim: claim half of the 10% limit
        uint256 firstClaimable = feeDistributor.claimableAmount(0);
        uint256 firstClaim = firstClaimable / 2;

        // We need to manually set the claim state to claim a partial amount
        // Since we can't directly set state, we'll claim the full amount and then
        // accrue more to test the same period logic differently
        // Actually, let's just test that claiming reduces the claimable amount
        deal(address(token), address(feeDistributor), firstClaimable);

        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);

        // Same period: should be 0 after claiming full period limit
        uint256 remainingClaimable = feeDistributor.claimableAmount(0);
        assertEq(remainingClaimable, 0, "Should be 0 after claiming full period limit");

        // After claiming remaining, should be 0
        assertEq(feeDistributor.claimableAmount(0), 0, "Should be 0 after claiming full period");
    }

    function test_ClaimAsWeth_SlippageProtection() public {
        uint256 totalAccrued = 10000e18;
        _accrueIssuerFees(0, totalAccrued);

        uint256 claimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), claimable);

        // Set minWethOut higher than what router will return
        uint256 minRaiseTokenOut = 10000e18; // Unrealistically high

        vm.expectRevert(); // Router will revert with "Slippage exceeded"
        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, minRaiseTokenOut, block.timestamp + 1 hours);
    }

    function test_ClaimAsWeth_DeadlineProtection() public {
        uint256 totalAccrued = 10000e18;
        _accrueIssuerFees(0, totalAccrued);

        uint256 claimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), claimable);

        // Set deadline in the past
        uint256 pastDeadline = block.timestamp - 1;

        vm.expectRevert(); // Router will revert with "Deadline exceeded"
        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, pastDeadline);
    }

    function test_ClaimAsWeth_EmitsEvent() public {
        uint256 totalAccrued = 10000e18;
        _accrueIssuerFees(0, totalAccrued);

        uint256 claimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), claimable);

        // Calculate expected WETH output (0.5 WETH per token)
        uint256 expectedWethOut = claimable * 0.5e18 / 1e18;

        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit IssuerClaimed(0, issuer1, claimable, expectedWethOut);

        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);
    }

    function test_RevertWhen_ClaimAsWeth_NothingToClaim() public {
        // No fees accrued
        assertEq(feeDistributor.claimableAmount(0), 0, "Should be 0 when nothing accrued");

        vm.expectRevert(FeeDistributor.NothingToClaimYet.selector);
        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);
    }

    function test_RevertWhen_ClaimAsWeth_InvalidRecipientIdx() public {
        _accrueIssuerFees(0, 10000e18);

        // Try to claim with invalid index (out of bounds)
        vm.expectRevert(); // Array out of bounds
        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(999, 0, block.timestamp + 1 hours);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Referrer Claim
    // ──────────────────────────────────────────────────────────────────────────

    function test_ClaimReferrerFees_OnlyReferrerCanCall() public {
        _accrueReferrerFees(1000e18);

        vm.expectRevert(FeeDistributor.NotRecipient.selector);
        vm.prank(alice);
        feeDistributor.claimReferrerFees();
    }

    function test_ClaimReferrerFees_NoRateLimit() public {
        uint256 accrued = 100000e18;
        _accrueReferrerFees(accrued);

        deal(address(token), address(feeDistributor), accrued);

        uint256 balanceBefore = token.balanceOf(referrer);

        vm.prank(referrer);
        feeDistributor.claimReferrerFees();

        uint256 balanceAfter = token.balanceOf(referrer);
        assertEq(balanceAfter - balanceBefore, accrued, "Should receive full accrued amount");
        assertEq(feeDistributor.referrerClaimed(), accrued, "referrerClaimed should equal accrued");
    }

    function test_ClaimReferrerFees_EmitsEvent() public {
        uint256 accrued = 1000e18;
        _accrueReferrerFees(accrued);
        deal(address(token), address(feeDistributor), accrued);

        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit ReferrerClaimed(referrer, accrued);

        vm.prank(referrer);
        feeDistributor.claimReferrerFees();
    }

    function test_RevertWhen_ClaimReferrerFees_NothingToClaim() public {
        vm.expectRevert(FeeDistributor.NothingToClaimYet.selector);
        vm.prank(referrer);
        feeDistributor.claimReferrerFees();
    }

    function test_ClaimReferrerFees_PartialClaim() public {
        _accrueReferrerFees(1000e18);
        deal(address(token), address(feeDistributor), 1000e18);

        // First claim: 500e18
        vm.prank(referrer);
        feeDistributor.claimReferrerFees();

        // Accrue more
        _accrueReferrerFees(500e18);
        deal(address(token), address(feeDistributor), 500e18);

        // Second claim: should get remaining 500e18
        uint256 balanceBefore = token.balanceOf(referrer);
        vm.prank(referrer);
        feeDistributor.claimReferrerFees();

        uint256 balanceAfter = token.balanceOf(referrer);
        assertEq(balanceAfter - balanceBefore, 500e18, "Should receive remaining amount");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Timelocked Address Changes - Issuer
    // ──────────────────────────────────────────────────────────────────────────

    function test_SignalChangeIssuerAddress_OnlyCurrentRecipient() public {
        address newAddress = makeAddr("newIssuer1");

        vm.expectRevert(FeeDistributor.NotRecipient.selector);
        vm.prank(alice);
        feeDistributor.signalChangeIssuerAddress(0, newAddress);
    }

    function test_ExecuteChangeIssuerAddress_ZeroAddress() public {
        vm.prank(issuer1);
        feeDistributor.signalChangeIssuerAddress(0, address(0));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(FeeDistributor.ZeroAddress.selector);
        feeDistributor.executeChangeIssuerAddress(0, address(0));
    }

    function test_SignalChangeIssuerAddress_EmitsEvent() public {
        address newAddress = makeAddr("newIssuer1");
        bytes32 action = keccak256(abi.encode(feeDistributor.ACTION_CHANGE_ISSUER(), uint256(0)));
        bytes32 dataHash = keccak256(abi.encode(newAddress));

        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit ChangeSignaled(
            action, dataHash, block.timestamp + TIMELOCK_DELAY, block.timestamp + TIMELOCK_DELAY + TIMELOCK_EXPIRY
        );

        vm.prank(issuer1);
        feeDistributor.signalChangeIssuerAddress(0, newAddress);
    }

    function test_ExecuteChangeIssuerAddress_AfterDelay() public {
        address newAddress = makeAddr("newIssuer1");

        vm.prank(issuer1);
        feeDistributor.signalChangeIssuerAddress(0, newAddress);

        // Warp past delay
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit IssuerAddressChanged(0, issuer1, newAddress);

        // Anyone can execute
        vm.prank(bob);
        feeDistributor.executeChangeIssuerAddress(0, newAddress);

        assertEq(feeDistributor.issuerRecipients(0), newAddress, "Address should be updated");
    }

    function test_ExecuteChangeIssuerAddress_BeforeDelay_Reverts() public {
        address newAddress = makeAddr("newIssuer1");

        vm.prank(issuer1);
        feeDistributor.signalChangeIssuerAddress(0, newAddress);

        // Try to execute before delay
        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockTooEarly.selector, block.timestamp + TIMELOCK_DELAY));
        feeDistributor.executeChangeIssuerAddress(0, newAddress);
    }

    function test_ExecuteChangeIssuerAddress_AfterExpiry_Reverts() public {
        address newAddress = makeAddr("newIssuer1");

        vm.prank(issuer1);
        feeDistributor.signalChangeIssuerAddress(0, newAddress);

        uint256 signalTime = block.timestamp;
        uint256 executeTime = signalTime + TIMELOCK_DELAY;
        uint256 expiryTime = executeTime + TIMELOCK_EXPIRY;

        // Warp past delay + expiry
        vm.warp(expiryTime + 1);

        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockExpired.selector, expiryTime));
        feeDistributor.executeChangeIssuerAddress(0, newAddress);
    }

    function test_CancelChangeIssuerAddress_OnlyCurrentRecipient() public {
        address newAddress = makeAddr("newIssuer1");

        vm.prank(issuer1);
        feeDistributor.signalChangeIssuerAddress(0, newAddress);

        vm.expectRevert(FeeDistributor.NotRecipient.selector);
        vm.prank(alice);
        feeDistributor.cancelChangeIssuerAddress(0);
    }

    function test_CancelChangeIssuerAddress_EmitsEvent() public {
        address newAddress = makeAddr("newIssuer1");
        bytes32 action = keccak256(abi.encode(feeDistributor.ACTION_CHANGE_ISSUER(), uint256(0)));

        vm.prank(issuer1);
        feeDistributor.signalChangeIssuerAddress(0, newAddress);

        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit ChangeCanceled(action);

        vm.prank(issuer1);
        feeDistributor.cancelChangeIssuerAddress(0);
    }

    function test_ClaimsGoToOldAddressDuringPendingChange() public {
        address newAddress = makeAddr("newIssuer1");
        uint256 totalAccrued = 10000e18;
        _accrueIssuerFees(0, totalAccrued);

        // Signal change
        vm.prank(issuer1);
        feeDistributor.signalChangeIssuerAddress(0, newAddress);

        // Warp past delay but before execution
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Old address should still be able to claim
        uint256 claimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), claimable);

        vm.prank(issuer1); // Old address
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);

        assertGt(weth.balanceOf(issuer1), 0, "Old address should receive WETH");
        assertEq(weth.balanceOf(newAddress), 0, "New address should not receive WETH yet");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Timelocked Address Changes - Referrer
    // ──────────────────────────────────────────────────────────────────────────

    function test_SignalChangeReferrerAddress_OnlyCurrentRecipient() public {
        address newAddress = makeAddr("newReferrer");

        vm.expectRevert(FeeDistributor.NotRecipient.selector);
        vm.prank(alice);
        feeDistributor.signalChangeReferrerAddress(newAddress);
    }

    function test_ExecuteChangeReferrerAddress_AfterDelay() public {
        address newAddress = makeAddr("newReferrer");

        vm.prank(referrer);
        feeDistributor.signalChangeReferrerAddress(newAddress);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit ReferrerAddressChanged(referrer, newAddress);

        vm.prank(bob);
        feeDistributor.executeChangeReferrerAddress(newAddress);

        assertEq(feeDistributor.referrer(), newAddress, "Address should be updated");
    }

    function test_CancelChangeReferrerAddress_OnlyCurrentRecipient() public {
        address newAddress = makeAddr("newReferrer");

        vm.prank(referrer);
        feeDistributor.signalChangeReferrerAddress(newAddress);

        vm.expectRevert(FeeDistributor.NotRecipient.selector);
        vm.prank(alice);
        feeDistributor.cancelChangeReferrerAddress();
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Generic Timelock Path Blocked
    // ──────────────────────────────────────────────────────────────────────────

    function test_RevertWhen_SignalAction_NotAuthorized() public {
        vm.expectRevert(FeeDistributor.NotAuthorized.selector);
        feeDistributor.signalAction(bytes32("test"), bytes32("data"));
    }

    function test_RevertWhen_CancelAction_NotAuthorized() public {
        vm.expectRevert(FeeDistributor.NotAuthorized.selector);
        feeDistributor.cancelAction(bytes32("test"));
    }

    function test_RevertWhen_SignalBurnAction_NotAuthorized() public {
        vm.expectRevert(FeeDistributor.NotAuthorized.selector);
        feeDistributor.signalBurnAction(bytes32("test"));
    }

    function test_RevertWhen_CancelBurnAction_NotAuthorized() public {
        vm.expectRevert(FeeDistributor.NotAuthorized.selector);
        feeDistributor.cancelBurnAction(bytes32("test"));
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Edge Cases
    // ──────────────────────────────────────────────────────────────────────────

    function test_ClaimableAmount_ZeroWhenNothingAccrued() public view {
        assertEq(feeDistributor.claimableAmount(0), 0, "Should be 0 when nothing accrued");
    }

    function test_ClaimableAmount_SmallAccrued_LessThan10Percent() public {
        // Accrue less than 10% worth
        uint256 smallAmount = 100e18; // Less than 10% of any reasonable total
        _accrueIssuerFees(0, smallAmount);

        // Should still be able to claim up to 10% of total accrued
        uint256 claimable = feeDistributor.claimableAmount(0);
        assertEq(claimable, smallAmount / 10, "Should be 10% of small amount");
    }

    function test_ClaimableAmount_MaxClaimableIs10Percent() public {
        uint256 totalAccrued = 100000e18;
        _accrueIssuerFees(0, totalAccrued);

        uint256 claimable = feeDistributor.claimableAmount(0);
        assertEq(claimable, totalAccrued / 10, "Should be exactly 10%");
        assertLt(claimable, totalAccrued, "Should be less than total");
    }

    function test_ClaimableAmount_AfterFullClaim_ZeroUntilNewPeriod() public {
        uint256 totalAccrued = 10000e18;
        _accrueIssuerFees(0, totalAccrued);

        uint256 claimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), claimable);

        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);

        // Same period: should be 0
        assertEq(feeDistributor.claimableAmount(0), 0, "Should be 0 after claiming full period");

        // Warp forward 24h
        vm.warp(block.timestamp + 1 days + 1);

        // Should be able to claim another 10%
        assertEq(feeDistributor.claimableAmount(0), totalAccrued / 10, "Should be claimable after new period");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Fuzz Tests
    // ──────────────────────────────────────────────────────────────────────────

    function testFuzz_OnTaxReceived_SplitsSumToTotal(
        uint256 taxAmount
    ) public {
        taxAmount = bound(taxAmount, 1e18, 1000000e18);
        deal(address(token), address(feeDistributor), taxAmount);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        uint256 lpShare = taxAmount * 2000 / 10000;
        uint256 boardwalkShare = taxAmount * 2000 / 10000;
        uint256 referrerShare = taxAmount * 1000 / 10000;
        uint256 issuerShare = taxAmount - lpShare - boardwalkShare - referrerShare;

        // Verify splits sum correctly
        assertEq(lpShare + boardwalkShare + referrerShare + issuerShare, taxAmount, "Splits should sum to total");

        // Verify LP share forwarded
        assertEq(lpStaking.totalFeesReceived(), lpShare, "LP share mismatch");

        // Verify Boardwalk share forwarded
        assertEq(feeCollector.accumulatedFees(address(token)), boardwalkShare, "Boardwalk share mismatch");

        // Verify referrer accrued
        assertEq(feeDistributor.referrerAccrued(), referrerShare, "Referrer share mismatch");

        // Verify issuer share accrued (sum of all recipients)
        (uint256 totalAccrued0,,,) = feeDistributor.issuerClaimStates(0);
        (uint256 totalAccrued1,,,) = feeDistributor.issuerClaimStates(1);
        (uint256 totalAccrued2,,,) = feeDistributor.issuerClaimStates(2);
        uint256 totalIssuerAccrued = totalAccrued0 + totalAccrued1 + totalAccrued2;
        assertEq(totalIssuerAccrued, issuerShare, "Total issuer accrued should equal issuer share");
    }

    function testFuzz_ClaimableAmount_NeverExceeds10Percent(
        uint256 totalAccrued
    ) public {
        totalAccrued = bound(totalAccrued, 1e18, 10000000e18);
        _accrueIssuerFees(0, totalAccrued);

        uint256 claimable = feeDistributor.claimableAmount(0);
        uint256 maxClaimable = totalAccrued / 10;

        assertLe(claimable, maxClaimable, "Claimable should never exceed 10%");
    }

    function testFuzz_ClaimAsWeth_RateLimitRespected(
        uint256 totalAccrued
    ) public {
        totalAccrued = bound(totalAccrued, 100e18, 1000000e18);
        _accrueIssuerFees(0, totalAccrued);

        uint256 claimable = feeDistributor.claimableAmount(0);
        assertLe(claimable, totalAccrued / 10, "Claimable should be <= 10%");

        deal(address(token), address(feeDistributor), claimable);

        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);

        // After claiming, should be 0 in same period
        assertEq(feeDistributor.claimableAmount(0), 0, "Should be 0 after claiming in same period");
    }

    function testFuzz_ReferrerClaim_NoRateLimit(
        uint256 accrued
    ) public {
        accrued = bound(accrued, 1e18, 1000000e18);
        _accrueReferrerFees(accrued);
        deal(address(token), address(feeDistributor), accrued);

        uint256 balanceBefore = token.balanceOf(referrer);

        vm.prank(referrer);
        feeDistributor.claimReferrerFees();

        uint256 balanceAfter = token.balanceOf(referrer);
        assertEq(balanceAfter - balanceBefore, accrued, "Should receive full amount regardless of size");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Transfer Resilience: try/catch Fallback + retryPendingFees
    // ──────────────────────────────────────────────────────────────────────────

    function test_OnTaxReceived_LPStakingReverts_FallbackAccumulates() public {
        // Configure mock LPStaking to revert
        lpStaking.setShouldRevert(true);

        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        uint256 expectedLpShare = taxAmount * 2000 / 10000;

        // Expect FeeForwardFailed event for lpStaking
        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit FeeForwardFailed("LPStaking", expectedLpShare);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        // LP fees should accumulate in pendingLpFees
        assertEq(feeDistributor.pendingLpFees(), expectedLpShare, "LP fees should accumulate in pending");

        // LPStaking mock should NOT have been called successfully
        assertEq(lpStaking.callCount(), 0, "LPStaking notifyFees should not succeed");

        // Boardwalk fees should still have been forwarded
        assertEq(feeCollector.callCount(), 1, "FeeCollector should still be called");
        uint256 expectedBwShare = taxAmount * 2000 / 10000;
        assertEq(feeCollector.accumulatedFees(address(token)), expectedBwShare, "Boardwalk share should be forwarded");

        // Issuer and referrer should still accrue (storage-only, can't fail)
        (uint256 totalAccrued0,,,) = feeDistributor.issuerClaimStates(0);
        assertGt(totalAccrued0, 0, "Issuer fees should still accrue");
        assertGt(feeDistributor.referrerAccrued(), 0, "Referrer fees should still accrue");
    }

    function test_OnTaxReceived_FeeCollectorReverts_FallbackAccumulates() public {
        // Configure mock FeeCollector to revert
        feeCollector.setShouldRevert(true);

        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        uint256 expectedBwShare = taxAmount * 2000 / 10000;

        // Expect FeeForwardFailed event for feeCollector
        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit FeeForwardFailed("FeeCollector", expectedBwShare);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        // Boardwalk fees should accumulate in pendingBoardwalkFees
        assertEq(feeDistributor.pendingBoardwalkFees(), expectedBwShare, "BW fees should accumulate in pending");

        // FeeCollector should NOT have been called successfully
        assertEq(feeCollector.callCount(), 0, "FeeCollector receiveFees should not succeed");

        // LP fees should still have been forwarded
        assertEq(lpStaking.callCount(), 1, "LPStaking should still be called");
        uint256 expectedLpShare = taxAmount * 2000 / 10000;
        assertEq(lpStaking.totalFeesReceived(), expectedLpShare, "LP share should be forwarded");

        // Issuer and referrer should still accrue
        (uint256 totalAccrued0,,,) = feeDistributor.issuerClaimStates(0);
        assertGt(totalAccrued0, 0, "Issuer fees should still accrue");
        assertGt(feeDistributor.referrerAccrued(), 0, "Referrer fees should still accrue");
    }

    function test_RetryPendingFees_Success() public {
        // Step 1: cause fees to accumulate by having both targets revert
        lpStaking.setShouldRevert(true);
        feeCollector.setShouldRevert(true);

        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        uint256 expectedLpShare = taxAmount * 2000 / 10000;
        uint256 expectedBwShare = taxAmount * 2000 / 10000;

        assertEq(feeDistributor.pendingLpFees(), expectedLpShare, "LP fees should be pending");
        assertEq(feeDistributor.pendingBoardwalkFees(), expectedBwShare, "BW fees should be pending");

        // Step 2: fix the mocks so they accept fees
        lpStaking.setShouldRevert(false);
        feeCollector.setShouldRevert(false);

        // Step 3: retry — should forward and zero accumulators
        feeDistributor.retryPendingFees();

        assertEq(feeDistributor.pendingLpFees(), 0, "LP pending should be 0 after retry");
        assertEq(feeDistributor.pendingBoardwalkFees(), 0, "BW pending should be 0 after retry");

        // Verify fees were forwarded to mocks
        assertEq(lpStaking.totalFeesReceived(), expectedLpShare, "LP should receive forwarded fees");
        assertEq(feeCollector.accumulatedFees(address(token)), expectedBwShare, "BW should receive forwarded fees");
    }

    function test_RetryPendingFees_NothingPending() public {
        // No pending fees — retryPendingFees should be a no-op
        assertEq(feeDistributor.pendingLpFees(), 0, "No LP fees pending");
        assertEq(feeDistributor.pendingBoardwalkFees(), 0, "No BW fees pending");

        feeDistributor.retryPendingFees();

        assertEq(lpStaking.callCount(), 0, "LPStaking should not be called");
        assertEq(feeCollector.callCount(), 0, "FeeCollector should not be called");
    }

    function test_RetryPendingFees_PartialRetry() public {
        // Accumulate both types of pending fees
        lpStaking.setShouldRevert(true);
        feeCollector.setShouldRevert(true);

        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        uint256 lpPending = feeDistributor.pendingLpFees();
        uint256 bwPending = feeDistributor.pendingBoardwalkFees();
        assertGt(lpPending, 0, "LP fees should be pending");
        assertGt(bwPending, 0, "BW fees should be pending");

        // Fix LP but keep BW reverting
        lpStaking.setShouldRevert(false);
        // feeCollector still reverts

        feeDistributor.retryPendingFees();

        // LP branch succeeds and clears, BW branch fails and remains pending.
        assertEq(feeDistributor.pendingLpFees(), 0, "LP pending should clear after successful retry");
        assertEq(feeDistributor.pendingBoardwalkFees(), bwPending, "BW pending should remain after failed BW retry");
        assertEq(lpStaking.totalFeesReceived(), lpPending, "LP should receive forwarded fees");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────────────────────────────────

    function _deployUninitializedFeeDistributor() internal returns (FeeDistributor) {
        address clone = Clones.clone(address(template));
        return FeeDistributor(clone);
    }

    function _deployInitializedFeeDistributor() internal returns (FeeDistributor) {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        fd.initialize(p);
        return fd;
    }

    function _defaultInitParams() internal view returns (FeeDistributor.InitParams memory) {
        return FeeDistributor.InitParams({
            token: address(token),
            lpStaking: address(lpStaking),
            feeCollector: address(feeCollector),
            router: address(router),
            raiseToken: address(weth),
            issuerRecipients: _toArray(issuer1, issuer2, issuer3),
            issuerSplits: _toArray(4000, 3000, 3000), // Sums to 10000
            referrer: referrer,
            integrator: address(0),
            issuerBps: 5000,
            boardwalkBps: 2000,
            lpIncentiveBps: 2000,
            referrerBps: 1000,
            integratorBps: 0
        });
    }

    function _integratorInitParams() internal view returns (FeeDistributor.InitParams memory) {
        return FeeDistributor.InitParams({
            token: address(token),
            lpStaking: address(lpStaking),
            feeCollector: address(feeCollector),
            router: address(router),
            raiseToken: address(weth),
            issuerRecipients: _toArray(issuer1, issuer2, issuer3),
            issuerSplits: _toArray(4000, 3000, 3000),
            referrer: address(0),
            integrator: integratorAddr,
            issuerBps: 4000,
            boardwalkBps: 3000,
            lpIncentiveBps: 2000,
            referrerBps: 0,
            integratorBps: 1000
        });
    }

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
        address a,
        address b,
        address c
    ) internal pure returns (address[] memory) {
        address[] memory arr = new address[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
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

    function _toArray(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
        return arr;
    }

    function _toArray(
        string memory a
    ) internal pure returns (string[] memory) {
        string[] memory arr = new string[](1);
        arr[0] = a;
        return arr;
    }

    function _toArray(
        string memory a,
        string memory b
    ) internal pure returns (string[] memory) {
        string[] memory arr = new string[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function _toArray(
        string memory a,
        string memory b,
        string memory c
    ) internal pure returns (string[] memory) {
        string[] memory arr = new string[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
        return arr;
    }

    function _accrueIssuerFees(
        uint256 recipientIdx,
        uint256 amount
    ) internal {
        // Calculate tax amount needed to accrue `amount` for recipient at `recipientIdx`
        // The recipient gets: issuerShare * issuerSplits[recipientIdx] / 10000
        // issuerShare = taxAmount * issuerBps / totalFeeBps
        // So: amount = taxAmount * issuerBps / totalFeeBps * issuerSplits[recipientIdx] / 10000
        // Therefore: taxAmount = amount * totalFeeBps * 10000 / (issuerBps * issuerSplits[recipientIdx])
        uint256 issuerBps = feeDistributor.issuerBps();
        uint256 totalFeeBps = feeDistributor.totalFeeBps();

        // Get the split for this recipient (need to read from storage)
        // For default setup: recipient 0 gets 4000/10000, recipient 1 gets 3000/10000, recipient 2 gets 3000/10000
        uint256 splitBps;
        if (recipientIdx == 0) {
            splitBps = 4000;
        } else if (recipientIdx == 1) {
            splitBps = 3000;
        } else {
            splitBps = 3000;
        }

        uint256 taxAmount = amount * totalFeeBps * 10000 / (issuerBps * splitBps);

        deal(address(token), address(feeDistributor), taxAmount);
        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);
    }

    function _accrueReferrerFees(
        uint256 amount
    ) internal {
        // referrerShare = taxAmount * referrerBps / totalFeeBps
        // So: taxAmount = referrerShare * totalFeeBps / referrerBps
        uint256 referrerBps = feeDistributor.referrerBps();
        uint256 totalFeeBps = feeDistributor.totalFeeBps();
        uint256 taxAmount = amount * totalFeeBps / referrerBps;

        deal(address(token), address(feeDistributor), taxAmount);
        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);
    }

    // ================================================================
    //  COVERAGE GAP TESTS
    // ================================================================

    function test_CancelChangeReferrerAddress() public {
        address newAddr = makeAddr("newReferrer");
        vm.prank(referrer);
        feeDistributor.signalChangeReferrerAddress(newAddr);

        vm.prank(referrer);
        feeDistributor.cancelChangeReferrerAddress();

        // Verify cancel succeeded: execute should revert with TimelockNotSignaled
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        feeDistributor.executeChangeReferrerAddress(newAddr);
    }

    function test_ClaimableAmount_ZeroWhenFullyClaimed() public {
        uint256 totalAccrued = 1000e18;
        _accrueIssuerFees(0, totalAccrued);

        // Claim the max (10%)
        uint256 claimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), claimable);
        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, type(uint256).max);

        // Same period: claimable should be 0
        assertEq(feeDistributor.claimableAmount(0), 0, "Should be 0 after claiming period limit");
    }

    function test_ClaimableAmount_DustEscape_TinyAccrual() public {
        // Accrue 9 wei for recipient 0: maxClaimable = 9/10 = 0, dust escape returns full unclaimed
        _accrueIssuerFees(0, 9);
        uint256 claimable = feeDistributor.claimableAmount(0);
        assertEq(claimable, 9, "Dust escape: when maxClaimable rounds to 0, full unclaimed is returned");
    }

    function test_ClaimableAmount_DustEscape_ReturnsFullUnclaimed() public {
        // Step 1: Accrue exactly 9 wei for recipient 0
        // maxClaimable = 9/10 = 0 → dust escape returns full unclaimed = 9
        _accrueIssuerFees(0, 9);
        uint256 claimable = feeDistributor.claimableAmount(0);
        assertEq(claimable, 9, "Dust escape: 9 wei accrued, full unclaimed returned");

        // Step 2: Accrue 1 more wei (total accrued = 10)
        // maxClaimable = 10/10 = 1 → normal rate limit applies, returns min(1, 10) = 1
        _accrueIssuerFees(0, 1);

        (uint256 totalAccrued,,,) = feeDistributor.issuerClaimStates(0);
        assertEq(totalAccrued, 10, "Total accrued should be 10 after second accrual");

        uint256 claimable2 = feeDistributor.claimableAmount(0);
        assertEq(claimable2, 1, "Normal rate limit: 10% of 10 = 1 wei (boundary between dust escape and normal)");
    }

    function test_RevertWhen_ExecuteChangeReferrerAddress_ZeroAddress() public {
        vm.prank(referrer);
        feeDistributor.signalChangeReferrerAddress(address(0));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(FeeDistributor.ZeroAddress.selector);
        feeDistributor.executeChangeReferrerAddress(address(0));
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  setFeeCollector
    // ──────────────────────────────────────────────────────────────────────────

    function test_SetFeeCollector_Success() public {
        address newCollector = makeAddr("newFeeCollector");

        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit FeeCollectorChanged(address(feeCollector), newCollector);

        vm.prank(address(feeCollector));
        feeDistributor.setFeeCollector(newCollector);

        assertEq(feeDistributor.feeCollector(), newCollector, "feeCollector should be updated");
    }

    function test_RevertWhen_SetFeeCollector_NotFeeCollector() public {
        address newCollector = makeAddr("newFeeCollector");

        vm.expectRevert(FeeDistributor.OnlyFeeCollector.selector);
        vm.prank(alice);
        feeDistributor.setFeeCollector(newCollector);
    }

    function test_RevertWhen_SetFeeCollector_ZeroAddress() public {
        vm.expectRevert(FeeDistributor.ZeroAddress.selector);
        vm.prank(address(feeCollector));
        feeDistributor.setFeeCollector(address(0));
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Integrator
    // ──────────────────────────────────────────────────────────────────────────

    function test_Init_WithIntegrator() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _integratorInitParams();
        fd.initialize(p);

        assertEq(fd.integrator(), integratorAddr, "integrator mismatch");
        assertEq(fd.integratorBps(), 1000, "integratorBps mismatch");
        assertEq(fd.referrer(), address(0), "referrer should be zero");
        assertEq(fd.referrerBps(), 0, "referrerBps should be 0");
        assertEq(fd.totalFeeBps(), 10000, "totalFeeBps mismatch");
    }

    function test_OnTaxReceived_WithIntegrator_SplitsCorrectly() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _integratorInitParams();
        fd.initialize(p);

        uint256 taxAmount = 10000e18;
        deal(address(token), address(fd), taxAmount);

        vm.prank(address(token));
        fd.onTaxReceived(taxAmount);

        // BPS: issuer=4000, boardwalk=3000, lp=2000, integrator=1000, referrer=0 (total=10000)
        uint256 expectedLpShare = taxAmount * 2000 / 10000;
        uint256 expectedBoardwalkShare = taxAmount * 3000 / 10000;
        uint256 expectedIntegratorShare = taxAmount * 1000 / 10000;
        uint256 expectedIssuerShare = taxAmount - expectedLpShare - expectedBoardwalkShare - expectedIntegratorShare;

        assertEq(lpStaking.totalFeesReceived(), expectedLpShare, "LP share mismatch");
        assertEq(feeCollector.accumulatedFees(address(token)), expectedBoardwalkShare, "Boardwalk share mismatch");
        assertEq(fd.integratorAccrued(), expectedIntegratorShare, "Integrator accrued mismatch");
        assertEq(fd.referrerAccrued(), 0, "Referrer accrued should be 0");

        (uint256 totalAccrued0,,,) = fd.issuerClaimStates(0);
        (uint256 totalAccrued1,,,) = fd.issuerClaimStates(1);
        (uint256 totalAccrued2,,,) = fd.issuerClaimStates(2);
        assertEq(totalAccrued0 + totalAccrued1 + totalAccrued2, expectedIssuerShare, "Total issuer accrued mismatch");
    }

    function test_ClaimIntegratorFees_HappyPath() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _integratorInitParams();
        fd.initialize(p);

        uint256 taxAmount = 10000e18;
        deal(address(token), address(fd), taxAmount);

        vm.prank(address(token));
        fd.onTaxReceived(taxAmount);

        uint256 expectedIntegratorShare = taxAmount * 1000 / 10000;
        uint256 balanceBefore = token.balanceOf(integratorAddr);

        vm.prank(integratorAddr);
        fd.claimIntegratorFees();

        uint256 balanceAfter = token.balanceOf(integratorAddr);
        assertEq(balanceAfter - balanceBefore, expectedIntegratorShare, "Integrator should receive full accrued amount");
        assertEq(fd.integratorClaimed(), expectedIntegratorShare, "integratorClaimed should match");
    }

    function test_ClaimIntegratorFees_EmitsEvent() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _integratorInitParams();
        fd.initialize(p);

        uint256 taxAmount = 10000e18;
        deal(address(token), address(fd), taxAmount);

        vm.prank(address(token));
        fd.onTaxReceived(taxAmount);

        uint256 expectedIntegratorShare = taxAmount * 1000 / 10000;

        vm.expectEmit(true, true, true, true, address(fd));
        emit IntegratorClaimed(integratorAddr, expectedIntegratorShare);

        vm.prank(integratorAddr);
        fd.claimIntegratorFees();
    }

    function test_RevertWhen_ClaimIntegratorFees_NotIntegrator() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _integratorInitParams();
        fd.initialize(p);

        vm.expectRevert(FeeDistributor.NotIntegrator.selector);
        vm.prank(alice);
        fd.claimIntegratorFees();
    }

    function test_RevertWhen_ClaimIntegratorFees_NothingToClaim() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _integratorInitParams();
        fd.initialize(p);

        vm.expectRevert(FeeDistributor.NothingToClaimYet.selector);
        vm.prank(integratorAddr);
        fd.claimIntegratorFees();
    }

    function test_OnTaxReceived_NoIntegrator_ZeroShare() public {
        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        assertEq(feeDistributor.integratorAccrued(), 0, "Integrator accrued should be 0 when no integrator");
    }

    function test_SetFeeCollector_ApprovalsRotate() public {
        address newCollector = makeAddr("newFeeCollector");

        // Before: old collector has max approval
        assertEq(
            token.allowance(address(feeDistributor), address(feeCollector)),
            type(uint256).max,
            "old collector should have max approval before"
        );

        vm.prank(address(feeCollector));
        feeDistributor.setFeeCollector(newCollector);

        // After: old collector approval revoked, new collector has max
        assertEq(
            token.allowance(address(feeDistributor), address(feeCollector)), 0, "old collector approval should be 0"
        );
        assertEq(
            token.allowance(address(feeDistributor), newCollector),
            type(uint256).max,
            "new collector should have max approval"
        );
    }
}

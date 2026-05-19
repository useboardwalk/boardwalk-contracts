// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeDistributor} from "src/core/FeeDistributor.sol";
import {ILPStaking} from "src/interfaces/ILPStaking.sol";
import {IBoardwalkFeeCollector} from "src/interfaces/IBoardwalkFeeCollector.sol";
import {Timelocked} from "src/base/Timelocked.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @dev Mock LPStaking that records notifyFees calls (configurable to revert for failure tests).
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

/// @dev Mock BoardwalkFeeCollector that records receiveFees calls (configurable to revert for
///      failure tests). Audit-fix stubs (executeSetGovernanceVault + ACTION_* getters) are kept
///      so MockFeeCollector continues to satisfy the IBoardwalkFeeCollector ABI.
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
        address tokenAddr,
        uint256 amount
    ) external override {
        if (shouldRevert) revert("MockFeeCollector: forced revert");
        accumulatedFees[tokenAddr] += amount;
        callCount++;
    }

    function swapToRaiseToken(
        address[] calldata,
        uint256[] calldata,
        uint256
    ) external pure override {
        revert("Not implemented");
    }

    function forwardRevenue() external pure override {
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

    function executeSetGovernanceVault(
        address
    ) external pure override {
        revert("Not implemented");
    }

    function ACTION_SET_TREASURY() external pure override returns (bytes32) {
        return keccak256("SET_TREASURY");
    }

    function ACTION_SET_KEEPER() external pure override returns (bytes32) {
        return keccak256("SET_KEEPER");
    }

    function ACTION_MIGRATE_COLLECTOR() external pure override returns (bytes32) {
        return keccak256("MIGRATE_COLLECTOR");
    }

    function ACTION_SET_GOVERNANCE_VAULT() external pure override returns (bytes32) {
        return keccak256("SET_GOVERNANCE_VAULT");
    }

    function governanceVault() external pure override returns (address) {
        revert("Not implemented");
    }

    function GOVERNANCE_BPS() external pure override returns (uint256) {
        revert("Not implemented");
    }
}

/// @dev Minimal mock implementing the only function FeeDistributor calls on the chain-level
///      IntegratorFeeCollector singleton: `receiveFees(address,uint256)`. Pulls via
///      `transferFrom` to mirror the production pull pattern (FD grants max allowance at init).
///      Configurable revert flag covers the negative-path try/catch fallback test.
contract MockIntegratorFeeCollector {
    address public lastToken;
    uint256 public lastAmount;
    uint256 public callCount;
    bool public shouldRevert;

    function setShouldRevert(
        bool _v
    ) external {
        shouldRevert = _v;
    }

    function receiveFees(address tokenAddr, uint256 amount) external {
        if (shouldRevert) revert("MockIntegratorFeeCollector: forced revert");
        IERC20(tokenAddr).transferFrom(msg.sender, address(this), amount);
        lastToken = tokenAddr;
        lastAmount = amount;
        callCount++;
    }
}

/// @dev Mock Router for swapExactTokensForTokens.
contract MockRouter {
    mapping(address => mapping(address => uint256)) public exchangeRates;

    function setExchangeRate(
        address tokenIn,
        address tokenOut,
        uint256 rate
    ) external {
        exchangeRates[tokenIn][tokenOut] = rate;
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
        address tokenOut = path[1];
        uint256 rate = exchangeRates[tokenIn][tokenOut];
        require(rate > 0, "Exchange rate not set");

        uint256 amountOut = (amountIn * rate) / 1e18;
        require(amountOut >= amountOutMin, "Slippage exceeded");

        ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(to, amountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}

/// @dev Simple ERC20 token for testing.
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

    /// @dev FeeDistributor calls updateExempt during BoardwalkFeeCollector migration.
    function updateExempt(address account, bool exempt) external {
        isExempt[account] = exempt;
    }
}

/// @title FeeDistributorTest
/// @notice Unit and fuzz tests for FeeDistributor against the post-refactor surface:
///         per-launch integrator role replaced by a chain-level `integratorCollector` pulled
///         via `receiveFees`; ancillary role removed entirely.
contract FeeDistributorTest is Test {
    // ============ Constants ============

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant TIMELOCK_DELAY = 7 days;
    uint256 internal constant TIMELOCK_EXPIRY = 7 days;

    // ============ State ============

    FeeDistributor internal template;
    FeeDistributor internal feeDistributor;
    MockLPStaking internal lpStaking;
    MockFeeCollector internal feeCollector;
    MockIntegratorFeeCollector internal integratorCollector;
    MockRouter internal router;
    MockERC20 internal token;
    MockERC20 internal weth;

    address internal integratorCollectorAddr;
    address internal issuer1;
    address internal issuer2;
    address internal issuer3;
    address internal referrer;
    address internal alice;
    address internal bob;

    // ============ Events (re-declared for vm.expectEmit) ============

    event TaxReceived(
        uint256 amount,
        uint256 lpShare,
        uint256 boardwalkShare,
        uint256 issuerShare,
        uint256 referrerShare,
        uint256 integratorShare
    );
    event IssuerClaimed(
        uint256 indexed recipientIdx, address indexed recipient, uint256 tokenAmount, uint256 raiseTokenAmount
    );
    event ReferrerClaimed(address indexed referrer, uint256 amount);
    event IssuerAddressChanged(uint256 indexed recipientIdx, address oldAddress, address newAddress);
    event ReferrerAddressChanged(address oldAddress, address newAddress);
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
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.label(issuer1, "issuer1");
        vm.label(issuer2, "issuer2");
        vm.label(issuer3, "issuer3");
        vm.label(referrer, "referrer");

        lpStaking = new MockLPStaking();
        feeCollector = new MockFeeCollector();
        integratorCollector = new MockIntegratorFeeCollector();
        router = new MockRouter();
        token = new MockERC20("TestToken", "TT");
        weth = new MockERC20("WETH", "WETH");
        integratorCollectorAddr = address(integratorCollector);
        vm.label(integratorCollectorAddr, "integratorCollector");

        // 1 token = 0.5 WETH for swap tests
        router.setExchangeRate(address(token), address(weth), 0.5e18);

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
        assertEq(feeDistributor.integratorBps(), 0, "integratorBps mismatch");
        assertEq(feeDistributor.totalFeeBps(), 10000, "totalFeeBps mismatch");
        assertEq(feeDistributor.referrer(), referrer, "referrer mismatch");
        assertEq(feeDistributor.integratorCollector(), address(0), "integratorCollector should be unset by default");
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
        p.issuerBps = 6000; // Adjust to keep total = 10000

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
        p.issuerSplits = _toArray(3000, 3000, 3000); // sums to 9000, not 10000

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
        p.integratorBps = 0;

        vm.expectRevert(FeeDistributor.InvalidFeeBps.selector);
        fd.initialize(p);
    }

    function test_Constructor_DisablesInitOnTemplate() public {
        FeeDistributor.InitParams memory p = _defaultInitParams();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        template.initialize(p);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Initialization — Integrator Collector (post-refactor)
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice With a non-zero integratorBps, the chain-level integrator collector address must
    ///         be wired and granted max allowance for the pull pattern.
    function test_Init_WithIntegratorCollector() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _integratorInitParams();
        fd.initialize(p);

        assertEq(fd.integratorCollector(), integratorCollectorAddr, "integratorCollector mismatch");
        assertEq(fd.integratorBps(), 1000, "integratorBps mismatch");
        assertEq(fd.totalFeeBps(), 10000, "totalFeeBps mismatch");
        assertEq(
            token.allowance(address(fd), integratorCollectorAddr),
            type(uint256).max,
            "integratorCollector should receive max allowance"
        );
    }

    /// @notice The defensive case: collector unwired AND integratorBps == 0 succeeds and skips
    ///         the conditional approval. Approve(address(0), max) would revert in OZ ERC20, so a
    ///         successful init proves the conditional branch was honored.
    function test_Init_ZeroIntegratorBpsAndZeroCollector_AllowsSkippedApproval() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _defaultInitParams();
        // Default already has integratorBps == 0 and integratorCollector == address(0).
        assertEq(p.integratorBps, 0, "default integratorBps should be 0");
        assertEq(p.integratorCollector, address(0), "default integratorCollector should be 0");

        fd.initialize(p);

        assertEq(fd.integratorCollector(), address(0), "integratorCollector should remain unset");
        assertEq(fd.integratorBps(), 0, "integratorBps should remain 0");
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

        uint256 expectedLpShare = taxAmount * 2000 / 10000; // 2000e18
        uint256 expectedBoardwalkShare = taxAmount * 2000 / 10000; // 2000e18
        uint256 expectedReferrerShare = taxAmount * 1000 / 10000; // 1000e18
        uint256 expectedIssuerShare = taxAmount - expectedLpShare - expectedBoardwalkShare - expectedReferrerShare;

        assertEq(lpStaking.totalFeesReceived(), expectedLpShare, "LP share mismatch");
        assertEq(feeCollector.accumulatedFees(address(token)), expectedBoardwalkShare, "Boardwalk share mismatch");
        assertEq(feeDistributor.referrerAccrued(), expectedReferrerShare, "Referrer accrued mismatch");

        (uint256 totalAccrued0,,,) = feeDistributor.issuerClaimStates(0);
        (uint256 totalAccrued1,,,) = feeDistributor.issuerClaimStates(1);
        (uint256 totalAccrued2,,,) = feeDistributor.issuerClaimStates(2);

        uint256 issuer1Accrued = expectedIssuerShare * 4000 / 10000;
        uint256 issuer2Accrued = expectedIssuerShare * 3000 / 10000;
        uint256 issuer3Accrued = expectedIssuerShare - issuer1Accrued - issuer2Accrued;

        assertEq(totalAccrued0, issuer1Accrued, "Issuer1 accrued mismatch");
        assertEq(totalAccrued1, issuer2Accrued, "Issuer2 accrued mismatch");
        assertEq(totalAccrued2, issuer3Accrued, "Issuer3 accrued (remainder) mismatch");
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

        uint256 issuerShare = taxAmount * 5000 / 10000;
        uint256 issuer1Accrued = issuerShare * 4000 / 10000;
        uint256 issuer2Accrued = issuerShare * 3000 / 10000;
        uint256 issuer3Accrued = issuerShare - issuer1Accrued - issuer2Accrued;

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
        p.issuerBps = 6000;
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
        p.issuerSplits = _toArray(3333, 6667);
        fd.initialize(p);

        uint256 taxAmount = 1000e18;
        deal(address(token), address(fd), taxAmount);

        vm.prank(address(token));
        fd.onTaxReceived(taxAmount);

        uint256 issuerShare = taxAmount * 5000 / 10000;
        uint256 issuer1Accrued = issuerShare * 3333 / 10000;
        uint256 issuer2Accrued = issuerShare - issuer1Accrued;

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
        emit TaxReceived(
            taxAmount, expectedLpShare, expectedBoardwalkShare, expectedIssuerShare, expectedReferrerShare, 0
        );

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
        (uint256 totalAccrued0,,,) = feeDistributor.issuerClaimStates(0);
        assertEq(totalAccrued0, 4000e18, "Issuer1 fees should accumulate");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  onTaxReceived — Integrator Collector (post-refactor pull pattern)
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Happy-path forward: integrator collector pulls via `transferFrom`, receives the
    ///         expected slice, and the new TaxReceived event carries the integratorShare.
    function test_OnTaxReceived_ForwardsToIntegratorCollector() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _integratorInitParams();
        fd.initialize(p);

        uint256 taxAmount = 10000e18;
        deal(address(token), address(fd), taxAmount);

        // BPS: issuer=4000, boardwalk=3000, lp=2000, integrator=1000, referrer=0 (total=10000)
        uint256 expectedLpShare = taxAmount * 2000 / 10000;
        uint256 expectedBoardwalkShare = taxAmount * 3000 / 10000;
        uint256 expectedIntegratorShare = taxAmount * 1000 / 10000;
        uint256 expectedIssuerShare = taxAmount - expectedLpShare - expectedBoardwalkShare - expectedIntegratorShare;

        vm.expectEmit(true, true, true, true, address(fd));
        emit TaxReceived(
            taxAmount, expectedLpShare, expectedBoardwalkShare, expectedIssuerShare, 0, expectedIntegratorShare
        );

        vm.prank(address(token));
        fd.onTaxReceived(taxAmount);

        assertEq(lpStaking.totalFeesReceived(), expectedLpShare, "LP share mismatch");
        assertEq(feeCollector.accumulatedFees(address(token)), expectedBoardwalkShare, "Boardwalk share mismatch");
        assertEq(integratorCollector.callCount(), 1, "Integrator collector should be called once");
        assertEq(integratorCollector.lastAmount(), expectedIntegratorShare, "Integrator collector lastAmount mismatch");
        assertEq(integratorCollector.lastToken(), address(token), "Integrator collector lastToken mismatch");
        assertEq(
            token.balanceOf(integratorCollectorAddr),
            expectedIntegratorShare,
            "Integrator collector should hold pulled tokens"
        );
        assertEq(fd.pendingIntegratorFees(), 0, "pendingIntegratorFees should be 0 on happy path");

        (uint256 totalAccrued0,,,) = fd.issuerClaimStates(0);
        (uint256 totalAccrued1,,,) = fd.issuerClaimStates(1);
        (uint256 totalAccrued2,,,) = fd.issuerClaimStates(2);
        assertEq(totalAccrued0 + totalAccrued1 + totalAccrued2, expectedIssuerShare, "Total issuer accrued mismatch");
    }

    /// @notice A reverting integrator collector must NOT brick the tax callback. The slice is
    ///         held in `pendingIntegratorFees` and a `FeeForwardFailed("Integrator", amount)`
    ///         event is emitted — same try/catch pattern as LP/boardwalk forwards.
    function test_OnTaxReceived_IntegratorCollectorReverts_AccumulatesPending() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _integratorInitParams();
        fd.initialize(p);

        integratorCollector.setShouldRevert(true);

        uint256 taxAmount = 10000e18;
        uint256 expectedIntegratorShare = taxAmount * 1000 / 10000;
        deal(address(token), address(fd), taxAmount);

        vm.expectEmit(true, true, true, true, address(fd));
        emit FeeForwardFailed("Integrator", expectedIntegratorShare);

        vm.prank(address(token));
        fd.onTaxReceived(taxAmount);

        assertEq(
            fd.pendingIntegratorFees(),
            expectedIntegratorShare,
            "Integrator share should accumulate in pendingIntegratorFees"
        );
        assertEq(integratorCollector.callCount(), 0, "Integrator receiveFees should not have succeeded");
        assertEq(token.balanceOf(integratorCollectorAddr), 0, "No tokens should have been pulled");

        // Other downstream forwards still ran on the same call.
        assertEq(lpStaking.callCount(), 1, "LP forward should still succeed");
        assertEq(feeCollector.callCount(), 1, "Boardwalk forward should still succeed");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Issuer Raise-Token Claim
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
        _accrueIssuerFees(0, 100000e18);
        _accrueIssuerFees(1, 100000e18);

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

        uint256 firstClaimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), firstClaimable);

        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, type(uint256).max);

        vm.warp(block.timestamp + 1 days + 1);

        // Cap = unclaimed / 10. First claim took 10% of totalAccrued, so the next window's cap
        // is (totalAccrued - firstClaimable) / 10.
        uint256 unclaimedAfterFirst = totalAccrued - firstClaimable;
        uint256 secondClaimable = feeDistributor.claimableAmount(0);
        assertEq(secondClaimable, unclaimedAfterFirst / 10, "Cap is 10% of live unclaimed in new period");

        deal(address(token), address(feeDistributor), secondClaimable);
        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, type(uint256).max);
    }

    function test_ClaimAsWeth_RateLimit_SamePeriod_SubtractsClaimed() public {
        uint256 totalAccrued = 100000e18;
        _accrueIssuerFees(0, totalAccrued);

        uint256 firstClaimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), firstClaimable);

        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);

        uint256 remainingClaimable = feeDistributor.claimableAmount(0);
        assertEq(remainingClaimable, 0, "Should be 0 after claiming full period limit");
    }

    function test_ClaimAsWeth_SlippageProtection() public {
        uint256 totalAccrued = 10000e18;
        _accrueIssuerFees(0, totalAccrued);

        uint256 claimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), claimable);

        uint256 minRaiseTokenOut = 10000e18; // unrealistically high

        vm.expectRevert();
        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, minRaiseTokenOut, block.timestamp + 1 hours);
    }

    function test_ClaimAsWeth_DeadlineProtection() public {
        uint256 totalAccrued = 10000e18;
        _accrueIssuerFees(0, totalAccrued);

        uint256 claimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), claimable);

        uint256 pastDeadline = block.timestamp - 1;

        vm.expectRevert();
        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, pastDeadline);
    }

    function test_ClaimAsWeth_EmitsEvent() public {
        uint256 totalAccrued = 10000e18;
        _accrueIssuerFees(0, totalAccrued);

        uint256 claimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), claimable);

        uint256 expectedWethOut = claimable * 0.5e18 / 1e18;

        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit IssuerClaimed(0, issuer1, claimable, expectedWethOut);

        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);
    }

    function test_RevertWhen_ClaimAsWeth_NothingToClaim() public {
        assertEq(feeDistributor.claimableAmount(0), 0, "Should be 0 when nothing accrued");

        vm.expectRevert(FeeDistributor.NothingToClaimYet.selector);
        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);
    }

    function test_RevertWhen_ClaimAsWeth_InvalidRecipientIdx() public {
        _accrueIssuerFees(0, 10000e18);

        vm.expectRevert();
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

        vm.prank(referrer);
        feeDistributor.claimReferrerFees();

        _accrueReferrerFees(500e18);
        deal(address(token), address(feeDistributor), 500e18);

        uint256 balanceBefore = token.balanceOf(referrer);
        vm.prank(referrer);
        feeDistributor.claimReferrerFees();

        uint256 balanceAfter = token.balanceOf(referrer);
        assertEq(balanceAfter - balanceBefore, 500e18, "Should receive remaining amount");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Timelocked Address Changes — Issuer
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

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit IssuerAddressChanged(0, issuer1, newAddress);

        vm.prank(bob);
        feeDistributor.executeChangeIssuerAddress(0, newAddress);

        assertEq(feeDistributor.issuerRecipients(0), newAddress, "Address should be updated");
    }

    function test_ExecuteChangeIssuerAddress_BeforeDelay_Reverts() public {
        address newAddress = makeAddr("newIssuer1");

        vm.prank(issuer1);
        feeDistributor.signalChangeIssuerAddress(0, newAddress);

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

        vm.prank(issuer1);
        feeDistributor.signalChangeIssuerAddress(0, newAddress);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        uint256 claimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), claimable);

        vm.prank(issuer1); // old address
        feeDistributor.claimAsRaiseToken(0, 0, block.timestamp + 1 hours);

        assertGt(weth.balanceOf(issuer1), 0, "Old address should receive WETH");
        assertEq(weth.balanceOf(newAddress), 0, "New address should not receive WETH yet");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Timelocked Address Changes — Referrer
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

    function test_CancelChangeReferrerAddress() public {
        address newAddr = makeAddr("newReferrer");
        vm.prank(referrer);
        feeDistributor.signalChangeReferrerAddress(newAddr);

        vm.prank(referrer);
        feeDistributor.cancelChangeReferrerAddress();

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        feeDistributor.executeChangeReferrerAddress(newAddr);
    }

    function test_RevertWhen_ExecuteChangeReferrerAddress_ZeroAddress() public {
        vm.prank(referrer);
        feeDistributor.signalChangeReferrerAddress(address(0));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(FeeDistributor.ZeroAddress.selector);
        feeDistributor.executeChangeReferrerAddress(address(0));
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
    //  Edge Cases — claimableAmount
    // ──────────────────────────────────────────────────────────────────────────

    function test_ClaimableAmount_ZeroWhenNothingAccrued() public view {
        assertEq(feeDistributor.claimableAmount(0), 0, "Should be 0 when nothing accrued");
    }

    function test_ClaimableAmount_SmallAccrued_LessThan10Percent() public {
        uint256 smallAmount = 100e18;
        _accrueIssuerFees(0, smallAmount);

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

        assertEq(feeDistributor.claimableAmount(0), 0, "Should be 0 after claiming full period");

        vm.warp(block.timestamp + 1 days + 1);

        // Cap = unclaimed / 10. First claim took 10% of totalAccrued, so the new-period cap
        // is (totalAccrued - claimable) / 10.
        uint256 unclaimedAfterFirst = totalAccrued - claimable;
        assertEq(feeDistributor.claimableAmount(0), unclaimedAfterFirst / 10, "10% of live unclaimed in new period");
    }

    function test_ClaimableAmount_ZeroWhenFullyClaimed() public {
        uint256 totalAccrued = 1000e18;
        _accrueIssuerFees(0, totalAccrued);

        uint256 claimable = feeDistributor.claimableAmount(0);
        deal(address(token), address(feeDistributor), claimable);
        vm.prank(issuer1);
        feeDistributor.claimAsRaiseToken(0, 0, type(uint256).max);

        assertEq(feeDistributor.claimableAmount(0), 0, "Should be 0 after claiming period limit");
    }

    function test_ClaimableAmount_DustEscape_TinyAccrual() public {
        // 9 wei accrued: maxClaimable = 9/10 = 0 → dust escape returns full unclaimed.
        _accrueIssuerFees(0, 9);
        uint256 claimable = feeDistributor.claimableAmount(0);
        assertEq(claimable, 9, "Dust escape: when maxClaimable rounds to 0, full unclaimed is returned");
    }

    function test_ClaimableAmount_DustEscape_ReturnsFullUnclaimed() public {
        _accrueIssuerFees(0, 9);
        uint256 claimable = feeDistributor.claimableAmount(0);
        assertEq(claimable, 9, "Dust escape: 9 wei accrued, full unclaimed returned");

        // Top up to 10 wei total → maxClaimable = 1 → normal rate limit applies.
        _accrueIssuerFees(0, 1);

        (uint256 totalAccrued,,,) = feeDistributor.issuerClaimStates(0);
        assertEq(totalAccrued, 10, "Total accrued should be 10 after second accrual");

        uint256 claimable2 = feeDistributor.claimableAmount(0);
        assertEq(claimable2, 1, "Normal rate limit: 10% of 10 = 1 wei (boundary between dust escape and normal)");
    }

    /// @notice Under steady recurring accruals the cap stays bounded by `unclaimed / 10` and
    ///         does not inflate from the lifetime totalAccrued history.
    function test_ClaimableAmount_SteadyInflow_DoesNotInflateWithHistory() public {
        uint256 dailyAccrual = 1000e18;

        uint256 startTime = block.timestamp;
        uint256 totalClaimed;
        uint256 maxCapEver;

        for (uint256 i = 0; i < 30; i++) {
            vm.warp(startTime + i * (1 days + 1));
            _accrueIssuerFees(0, dailyAccrual);

            (uint256 totalAccrued, uint256 claimedSoFar,,) = feeDistributor.issuerClaimStates(0);
            uint256 unclaimed = totalAccrued - claimedSoFar;
            uint256 cap = feeDistributor.claimableAmount(0);

            if (unclaimed >= 10) {
                assertLe(cap, unclaimed / 10, "cap exceeds live unclaimed/10");
            }
            assertLe(cap, unclaimed, "cap exceeds unclaimed");

            if (cap > maxCapEver) maxCapEver = cap;

            if (cap > 0) {
                deal(address(token), address(feeDistributor), cap);
                vm.prank(issuer1);
                feeDistributor.claimAsRaiseToken(0, 0, type(uint256).max);
                totalClaimed += cap;
            }
        }

        // After 30 days at 1000e18/day, lifetime totalAccrued = 30000e18. A `totalAccrued / 10`
        // cap would read 3000e18, well above the 1000e18/day inflow. Live `unclaimed / 10`
        // keeps the cap bounded by the rolling backlog (~10 * dailyAccrual at equilibrium).
        assertLt(maxCapEver, 2000e18, "cap inflated with history");
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

        assertEq(lpShare + boardwalkShare + referrerShare + issuerShare, taxAmount, "Splits should sum to total");

        assertEq(lpStaking.totalFeesReceived(), lpShare, "LP share mismatch");
        assertEq(feeCollector.accumulatedFees(address(token)), boardwalkShare, "Boardwalk share mismatch");
        assertEq(feeDistributor.referrerAccrued(), referrerShare, "Referrer share mismatch");

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
        lpStaking.setShouldRevert(true);

        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        uint256 expectedLpShare = taxAmount * 2000 / 10000;

        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit FeeForwardFailed("LPStaking", expectedLpShare);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        assertEq(feeDistributor.pendingLpFees(), expectedLpShare, "LP fees should accumulate in pending");
        assertEq(lpStaking.callCount(), 0, "LPStaking notifyFees should not succeed");

        assertEq(feeCollector.callCount(), 1, "FeeCollector should still be called");
        uint256 expectedBwShare = taxAmount * 2000 / 10000;
        assertEq(feeCollector.accumulatedFees(address(token)), expectedBwShare, "Boardwalk share should be forwarded");

        (uint256 totalAccrued0,,,) = feeDistributor.issuerClaimStates(0);
        assertGt(totalAccrued0, 0, "Issuer fees should still accrue");
        assertGt(feeDistributor.referrerAccrued(), 0, "Referrer fees should still accrue");
    }

    function test_OnTaxReceived_FeeCollectorReverts_FallbackAccumulates() public {
        feeCollector.setShouldRevert(true);

        uint256 taxAmount = 10000e18;
        deal(address(token), address(feeDistributor), taxAmount);

        uint256 expectedBwShare = taxAmount * 2000 / 10000;

        vm.expectEmit(true, true, true, true, address(feeDistributor));
        emit FeeForwardFailed("FeeCollector", expectedBwShare);

        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);

        assertEq(feeDistributor.pendingBoardwalkFees(), expectedBwShare, "BW fees should accumulate in pending");
        assertEq(feeCollector.callCount(), 0, "FeeCollector receiveFees should not succeed");

        assertEq(lpStaking.callCount(), 1, "LPStaking should still be called");
        uint256 expectedLpShare = taxAmount * 2000 / 10000;
        assertEq(lpStaking.totalFeesReceived(), expectedLpShare, "LP share should be forwarded");

        (uint256 totalAccrued0,,,) = feeDistributor.issuerClaimStates(0);
        assertGt(totalAccrued0, 0, "Issuer fees should still accrue");
        assertGt(feeDistributor.referrerAccrued(), 0, "Referrer fees should still accrue");
    }

    function test_RetryPendingFees_Success() public {
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

        lpStaking.setShouldRevert(false);
        feeCollector.setShouldRevert(false);

        feeDistributor.retryPendingFees();

        assertEq(feeDistributor.pendingLpFees(), 0, "LP pending should be 0 after retry");
        assertEq(feeDistributor.pendingBoardwalkFees(), 0, "BW pending should be 0 after retry");

        assertEq(lpStaking.totalFeesReceived(), expectedLpShare, "LP should receive forwarded fees");
        assertEq(feeCollector.accumulatedFees(address(token)), expectedBwShare, "BW should receive forwarded fees");
    }

    function test_RetryPendingFees_NothingPending() public {
        assertEq(feeDistributor.pendingLpFees(), 0, "No LP fees pending");
        assertEq(feeDistributor.pendingBoardwalkFees(), 0, "No BW fees pending");

        feeDistributor.retryPendingFees();

        assertEq(lpStaking.callCount(), 0, "LPStaking should not be called");
        assertEq(feeCollector.callCount(), 0, "FeeCollector should not be called");
    }

    function test_RetryPendingFees_PartialRetry() public {
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

        lpStaking.setShouldRevert(false);
        // feeCollector still reverts

        feeDistributor.retryPendingFees();

        assertEq(feeDistributor.pendingLpFees(), 0, "LP pending should clear after successful retry");
        assertEq(feeDistributor.pendingBoardwalkFees(), bwPending, "BW pending should remain after failed BW retry");
        assertEq(lpStaking.totalFeesReceived(), lpPending, "LP should receive forwarded fees");
    }

    /// @notice The new pendingIntegratorFees branch of retryPendingFees flushes the integrator
    ///         bucket once the collector accepts. Mirrors the LP / boardwalk retry semantics.
    function test_RetryPendingFees_FlushesIntegrator() public {
        FeeDistributor fd = _deployUninitializedFeeDistributor();
        FeeDistributor.InitParams memory p = _integratorInitParams();
        fd.initialize(p);

        // Accumulate via revert.
        integratorCollector.setShouldRevert(true);
        uint256 taxAmount = 10000e18;
        uint256 expectedShare = taxAmount * 1000 / 10000;
        deal(address(token), address(fd), taxAmount);

        vm.prank(address(token));
        fd.onTaxReceived(taxAmount);

        assertEq(fd.pendingIntegratorFees(), expectedShare, "Integrator pending should accumulate");
        assertEq(token.balanceOf(integratorCollectorAddr), 0, "No tokens should have been pulled yet");

        // Make collector accept and flush.
        integratorCollector.setShouldRevert(false);
        fd.retryPendingFees();

        assertEq(fd.pendingIntegratorFees(), 0, "Integrator pending should clear after retry");
        assertEq(integratorCollector.callCount(), 1, "Integrator receiveFees should fire on retry");
        assertEq(integratorCollector.lastAmount(), expectedShare, "Integrator collector lastAmount mismatch");
        assertEq(
            token.balanceOf(integratorCollectorAddr), expectedShare, "Integrator collector should hold pulled tokens"
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  setFeeCollector — BoardwalkFeeCollector rotation
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

    /// @notice Cannot rotate to an address already exempt — boolean-mapping aliasing protection.
    function test_RevertWhen_SetFeeCollector_DuplicateExempt() public {
        address candidate = makeAddr("alreadyExempt");
        token.updateExempt(candidate, true);

        vm.prank(address(feeCollector));
        vm.expectRevert(FeeDistributor.DuplicateRoleAddress.selector);
        feeDistributor.setFeeCollector(candidate);
    }

    function test_SetFeeCollector_ApprovalsRotate() public {
        address newCollector = makeAddr("newFeeCollector");

        assertEq(
            token.allowance(address(feeDistributor), address(feeCollector)),
            type(uint256).max,
            "old collector should have max approval before"
        );

        vm.prank(address(feeCollector));
        feeDistributor.setFeeCollector(newCollector);

        assertEq(
            token.allowance(address(feeDistributor), address(feeCollector)), 0, "old collector approval should be 0"
        );
        assertEq(
            token.allowance(address(feeDistributor), newCollector),
            type(uint256).max,
            "new collector should have max approval"
        );
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

    /// @dev Default params: integrator role disabled (bps == 0, collector unwired). Sums to 10000.
    function _defaultInitParams() internal view returns (FeeDistributor.InitParams memory) {
        return FeeDistributor.InitParams({
            token: address(token),
            lpStaking: address(lpStaking),
            feeCollector: address(feeCollector),
            integratorCollector: address(0),
            router: address(router),
            raiseToken: address(weth),
            issuerRecipients: _toArray(issuer1, issuer2, issuer3),
            issuerSplits: _toArray(4000, 3000, 3000),
            referrer: referrer,
            issuerBps: 5000,
            boardwalkBps: 2000,
            lpIncentiveBps: 2000,
            referrerBps: 1000,
            integratorBps: 0
        });
    }

    /// @dev Wires the chain-level integrator collector with a non-zero bucket and drops the
    ///      referrer for clean integrator-share assertions. Sums to 10000.
    function _integratorInitParams() internal view returns (FeeDistributor.InitParams memory) {
        return FeeDistributor.InitParams({
            token: address(token),
            lpStaking: address(lpStaking),
            feeCollector: address(feeCollector),
            integratorCollector: integratorCollectorAddr,
            router: address(router),
            raiseToken: address(weth),
            issuerRecipients: _toArray(issuer1, issuer2, issuer3),
            issuerSplits: _toArray(4000, 3000, 3000),
            referrer: address(0),
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

    /// @dev Drives `onTaxReceived` with a tax amount sized to deposit `amount` for
    ///      `recipientIdx` against the default issuer-split layout (4000/3000/3000).
    function _accrueIssuerFees(
        uint256 recipientIdx,
        uint256 amount
    ) internal {
        uint256 issuerBps = feeDistributor.issuerBps();
        uint256 totalFeeBps = feeDistributor.totalFeeBps();

        uint256 splitBps;
        if (recipientIdx == 0) {
            splitBps = 4000;
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
        uint256 referrerBps = feeDistributor.referrerBps();
        uint256 totalFeeBps = feeDistributor.totalFeeBps();
        uint256 taxAmount = amount * totalFeeBps / referrerBps;

        deal(address(token), address(feeDistributor), taxAmount);
        vm.prank(address(token));
        feeDistributor.onTaxReceived(taxAmount);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchFactory} from "src/core/LaunchFactory.sol";
import {ILaunchFactory} from "src/interfaces/ILaunchFactory.sol";
import {IBoardwalkToken} from "src/interfaces/IBoardwalkToken.sol";
import {IFeeDistributor} from "src/interfaces/IFeeDistributor.sol";
import {IPresaleManager} from "src/interfaces/IPresaleManager.sol";
import {BoardwalkToken} from "src/core/BoardwalkToken.sol";
import {FeeDistributor} from "src/core/FeeDistributor.sol";
import {PresaleManager} from "src/core/PresaleManager.sol";
import {VestingStream} from "src/core/VestingStream.sol";
import {LPStaking} from "src/core/LPStaking.sol";
import {IntegratorFeeCollector} from "src/core/IntegratorFeeCollector.sol";
import {Timelocked} from "src/base/Timelocked.sol";

// ============ Mocks ============

/// @dev Mock ERC20 token with mint and burn functions (for BMX and WETH)
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

    function burn(
        uint256 amount
    ) external {
        _burn(msg.sender, amount);
    }
}

/// @dev Mock contracts that record initialization calls
contract MockFeeDistributor {
    bool public initialized;
    IFeeDistributor.InitParams public initParams;

    function initialize(
        IFeeDistributor.InitParams calldata p
    ) external {
        require(!initialized, "Already initialized");
        initialized = true;
        initParams = p;
    }

    function onTaxReceived(
        uint256
    ) external {}
}

contract MockPresaleManager {
    bool public initialized;
    address public token;
    address public feeDistributor;
    address public vestingStream;
    address public lpStaking;
    address public router;
    address public raiseToken;
    address public dexFactory;
    uint256 public duration;
    uint256 public presalePercent;
    uint256 public graduationThreshold;
    bool public hasDelay;
    address public factory;

    constructor() {
        factory = msg.sender;
    }

    function initialize(
        address _token,
        address _feeDistributor,
        address _vestingStream,
        address _lpStaking,
        address _router,
        address _raiseToken,
        address _dexFactory,
        uint256 _duration,
        uint256 _presalePercent,
        uint256 _graduationThreshold,
        bool _hasDelay
    ) external {
        require(!initialized, "Already initialized");
        initialized = true;
        token = _token;
        feeDistributor = _feeDistributor;
        vestingStream = _vestingStream;
        lpStaking = _lpStaking;
        router = _router;
        raiseToken = _raiseToken;
        dexFactory = _dexFactory;
        duration = _duration;
        presalePercent = _presalePercent;
        graduationThreshold = _graduationThreshold;
        hasDelay = _hasDelay;
    }

    function setVestingConfig(
        address[] calldata,
        uint256[] calldata
    ) external {
        require(msg.sender == factory, "Only factory");
    }
}

contract MockVestingStream {
    bool public initialized;

    function initialize(
        address,
        uint256,
        address[] calldata,
        uint256[] calldata
    ) external {
        require(!initialized, "Already initialized");
        initialized = true;
    }
}

contract MockLPStaking {
    bool public initialized;

    function initialize(
        address,
        address,
        address,
        uint256,
        uint256
    ) external {
        require(!initialized, "Already initialized");
        initialized = true;
    }
}

contract MockNFT {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 count) external {
        balanceOf[to] += count;
    }
}

contract RevertingNFT {
    function balanceOf(
        address
    ) external pure returns (uint256) {
        revert("broken");
    }
}

/// @dev Minimal mock router that exposes factory() for PresaleManager coherence check
contract MockRouterMinimal {
    address public factory;

    constructor(
        address _factory
    ) {
        factory = _factory;
    }
}

// ============ Test Contract ============

/// @title LaunchFactoryTest
/// @notice Unit and fuzz tests for LaunchFactory.
contract LaunchFactoryTest is Test {
    // ============ Constants ============

    uint256 internal constant BPS_DENOMINATOR = 10000;
    uint256 internal constant DEFAULT_BMX_BURN = 100e18;
    uint256 internal constant EXPRESS_DURATION = 24 hours;
    uint256 internal constant ADVANCED_DURATION = 7 days;
    uint256 internal constant MIN_PRESALE_PERCENT = 2500;
    uint256 internal constant MAX_PRESALE_PERCENT = 5000;
    uint256 internal constant GRADUATION_EXPRESS = 10 ether;
    uint256 internal constant GRADUATION_ADVANCED = 10 ether;
    uint256 internal constant TIMELOCK_DELAY = 7 days;
    uint256 internal constant TIMELOCK_EXPIRY = 7 days;

    // ============ State ============

    LaunchFactory internal factory;
    BoardwalkToken internal tokenTemplate;
    FeeDistributor internal feeDistributorTemplate;
    PresaleManager internal presaleTemplate;
    VestingStream internal vestingTemplate;
    LPStaking internal lpStakingTemplate;
    MockERC20 internal bmx;
    MockERC20 internal weth;

    address internal owner;
    address internal issuer;
    address internal referrer;
    address internal feeRecipient1;
    address internal feeRecipient2;
    address internal feeRecipient3;
    address internal feeRecipient4;
    address internal vestingRecipient1;
    address internal vestingRecipient2;
    address internal vestingRecipient3;
    address internal vestingRecipient4;
    address internal vestingRecipient5;
    address internal boardwalkRouter;
    address internal boardwalkDEXFactory;
    address internal boardwalkLPManager;
    address internal boardwalkFeeCollector;

    LaunchFactory.FeeBpsDefaults internal defaultFeeBps;
    IntegratorFeeCollector internal integratorCollector;
    address internal integratorAddress;

    // ============ Action Keys (local constants to avoid consuming vm.prank) ============

    bytes32 constant ACTION_SET_BMX_BURN = keccak256("SET_BMX_BURN");
    bytes32 constant ACTION_SET_GRADUATION_EXPRESS = keccak256("SET_GRADUATION_EXPRESS");
    bytes32 constant ACTION_SET_GRADUATION_ADVANCED = keccak256("SET_GRADUATION_ADVANCED");
    bytes32 constant ACTION_SET_EXPRESS_DURATION = keccak256("SET_EXPRESS_DURATION");
    bytes32 constant ACTION_SET_ADVANCED_DURATION = keccak256("SET_ADVANCED_DURATION");
    bytes32 constant ACTION_SET_FEE_DEFAULTS = keccak256("SET_FEE_DEFAULTS");
    bytes32 constant ACTION_SET_PRESALE_RANGE = keccak256("SET_PRESALE_RANGE");
    bytes32 constant ACTION_SET_FEE_COLLECTOR = keccak256("SET_FEE_COLLECTOR");

    // ============ Events (re-declared for vm.expectEmit) ============

    event LaunchCreated(
        address indexed token,
        address indexed issuer,
        string name,
        string ticker,
        string category,
        string description,
        LaunchFactory.LaunchPath path,
        string[] issuerFeeLabels,
        string[] vestingLabels
    );
    event BmxBurnAmountChanged(uint256 oldAmount, uint256 newAmount);
    event ChangeSignaled(bytes32 indexed action, bytes32 dataHash, uint256 executeTime, uint256 expiresAt);
    event ChangeExecuted(bytes32 indexed action);
    event ChangeCanceled(bytes32 indexed action);
    event FeeDefaultsChanged(uint256 issuer, uint256 boardwalk, uint256 incentive, uint256 referrer);
    event PresaleRangeChanged(uint256 oldMin, uint256 oldMax, uint256 newMin, uint256 newMax);
    event FeeCollectorChanged(address oldCollector, address newCollector);

    // ============ Setup ============

    function setUp() public {
        owner = makeAddr("owner");
        issuer = makeAddr("issuer");
        referrer = makeAddr("referrer");
        feeRecipient1 = makeAddr("feeRecipient1");
        feeRecipient2 = makeAddr("feeRecipient2");
        feeRecipient3 = makeAddr("feeRecipient3");
        feeRecipient4 = makeAddr("feeRecipient4");
        vestingRecipient1 = makeAddr("vestingRecipient1");
        vestingRecipient2 = makeAddr("vestingRecipient2");
        vestingRecipient3 = makeAddr("vestingRecipient3");
        vestingRecipient4 = makeAddr("vestingRecipient4");
        vestingRecipient5 = makeAddr("vestingRecipient5");
        boardwalkDEXFactory = makeAddr("boardwalkDEXFactory");
        boardwalkRouter = address(new MockRouterMinimal(boardwalkDEXFactory));
        boardwalkLPManager = makeAddr("boardwalkLPManager");
        boardwalkFeeCollector = makeAddr("boardwalkFeeCollector");

        // Deploy templates
        tokenTemplate = new BoardwalkToken();
        feeDistributorTemplate = new FeeDistributor();
        presaleTemplate = new PresaleManager();
        vestingTemplate = new VestingStream();
        lpStakingTemplate = new LPStaking();

        // Deploy mock tokens
        bmx = new MockERC20("BMX", "BMX");
        weth = new MockERC20("WETH", "WETH");

        // Set default fee BPS. Referrer is CARVED from boardwalk, not additive to total.
        // Integrator BPS is the immutable INTEGRATOR_BPS on the factory (passed via DeployParams.integratorBps below).
        // total = issuer + boardwalk + incentive + INTEGRATOR_BPS (referrer excluded).
        integratorAddress = makeAddr("integrator");
        defaultFeeBps = LaunchFactory.FeeBpsDefaults({
            issuer: 40, // 0.40%
            boardwalk: 45, // 0.45% (referrer carved from this at launch time)
            incentive: 28, // 0.28%
            referrer: 5, // 0.05% (carved from boardwalk when referrer present)
            total: 115 // 1.15% = 40+45+28+2 (integrator immutable, referrer not in total)
        });

        address[] memory _integrators = new address[](1);
        _integrators[0] = integratorAddress;
        uint256[] memory _splits = new uint256[](1);
        _splits[0] = 10_000;
        integratorCollector = new IntegratorFeeCollector(
            address(this), address(weth), boardwalkRouter, _integrators, _splits
        );

        // Deploy factory
        factory = new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(integratorCollector),
                integratorBps: 2,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: defaultFeeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );

        integratorCollector.setFactory(address(factory));

        // Label addresses for better traces
        vm.label(address(factory), "LaunchFactory");
        vm.label(address(bmx), "BMX");
        vm.label(address(weth), "WETH");
        vm.label(issuer, "issuer");
    }

    // ============ Initialization ============

    function test_Initialize_SetsAllImmutableValues() public view {
        assertEq(address(factory.TOKEN_IMPL()), address(tokenTemplate), "tokenImpl mismatch");
        assertEq(
            address(factory.FEE_DISTRIBUTOR_IMPL()), address(feeDistributorTemplate), "feeDistributorImpl mismatch"
        );
        assertEq(address(factory.PRESALE_IMPL()), address(presaleTemplate), "presaleImpl mismatch");
        assertEq(address(factory.VESTING_IMPL()), address(vestingTemplate), "vestingImpl mismatch");
        assertEq(address(factory.LP_STAKING_IMPL()), address(lpStakingTemplate), "lpStakingImpl mismatch");
        assertEq(address(factory.BMX()), address(bmx), "BMX mismatch");
        assertEq(address(factory.RAISE_TOKEN()), address(weth), "raise token mismatch");
        assertEq(address(factory.BOARDWALK_ROUTER()), boardwalkRouter, "router mismatch");
        assertEq(address(factory.BOARDWALK_DEX_FACTORY()), boardwalkDEXFactory, "dexFactory mismatch");
        assertEq(address(factory.BOARDWALK_LP_MANAGER()), boardwalkLPManager, "lpManager mismatch");
        assertEq(address(factory.boardwalkFeeCollector()), boardwalkFeeCollector, "feeCollector mismatch");
    }

    function test_Initialize_SetsDefaultParameters() public view {
        assertEq(factory.bmxBurnAmount(), DEFAULT_BMX_BURN, "bmxBurnAmount mismatch");
        assertEq(factory.expressDuration(), EXPRESS_DURATION, "expressDuration mismatch");
        assertEq(factory.advancedDuration(), ADVANCED_DURATION, "advancedDuration mismatch");
        assertEq(factory.minPresalePercent(), MIN_PRESALE_PERCENT, "minPresalePercent mismatch");
        assertEq(factory.maxPresalePercent(), MAX_PRESALE_PERCENT, "maxPresalePercent mismatch");
        assertEq(factory.graduationExpress(), GRADUATION_EXPRESS, "graduationExpress mismatch");
        assertEq(factory.graduationAdvanced(), GRADUATION_ADVANCED, "graduationAdvanced mismatch");
        assertFalse(factory.isActionBurned(factory.ACTION_SET_BMX_BURN()), "ACTION_SET_BMX_BURN should not be burned");
    }

    function test_Initialize_SetsFeeDefaults() public view {
        (
            uint256 issuerBps,
            uint256 boardwalkBps,
            uint256 incentiveBps,
            uint256 referrerBps,
            uint256 integratorBps,
            uint256 totalBps
        ) = factory.currentFeeBps();
        assertEq(issuerBps, defaultFeeBps.issuer, "issuer BPS mismatch");
        assertEq(boardwalkBps, defaultFeeBps.boardwalk, "boardwalk BPS mismatch");
        assertEq(incentiveBps, defaultFeeBps.incentive, "incentive BPS mismatch");
        assertEq(referrerBps, defaultFeeBps.referrer, "referrer BPS mismatch");
        // Integrator BPS is the immutable INTEGRATOR_BPS, not part of FeeBpsDefaults anymore.
        assertEq(integratorBps, factory.INTEGRATOR_BPS(), "integrator BPS should match INTEGRATOR_BPS immutable");
        assertEq(integratorBps, 2, "INTEGRATOR_BPS should equal the value passed to constructor");
        assertEq(totalBps, defaultFeeBps.total, "total BPS mismatch");
    }

    function test_Initialize_SetsOwner() public view {
        assertEq(factory.owner(), owner, "owner mismatch");
    }

    // ============ CreateLaunch - Express Path ============

    function test_CreateLaunch_ExpressPath_Success() public {
        // Setup BMX balance and approval
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        // Build Express config
        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();

        // Create launch
        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);

        // Verify BMX was burned
        assertEq(bmx.balanceOf(issuer), 0, "BMX should be burned from issuer");
        assertEq(bmx.balanceOf(factory.DEAD_ADDRESS()), DEFAULT_BMX_BURN, "BMX should be in dead address");

        // Verify launch info
        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);
        assertEq(info.token, tokenAddr, "token address mismatch");
        assertTrue(info.feeDistributor != address(0), "feeDistributor should be set");
        assertTrue(info.presaleManager != address(0), "presaleManager should be set");
        assertTrue(info.lpStaking != address(0), "lpStaking should be set");
        assertEq(info.issuer, issuer, "issuer mismatch");
        assertEq(uint256(info.path), uint256(LaunchFactory.LaunchPath.EXPRESS), "path mismatch");
        assertEq(info.createdAt, block.timestamp, "createdAt mismatch");

        // Verify all clones are different addresses
        assertTrue(info.token != info.feeDistributor, "token != feeDistributor");
        assertTrue(info.token != info.presaleManager, "token != presaleManager");
        assertTrue(info.token != info.lpStaking, "token != lpStaking");
        assertTrue(info.feeDistributor != info.presaleManager, "feeDistributor != presaleManager");
        assertTrue(info.feeDistributor != info.lpStaking, "feeDistributor != lpStaking");
        assertTrue(info.presaleManager != info.lpStaking, "presaleManager != lpStaking");

        // Verify token is initialized
        IBoardwalkToken token = IBoardwalkToken(tokenAddr);
        assertEq(token.baseTaxBps(), defaultFeeBps.total, "token baseTaxBps mismatch");
        assertEq(token.feeDistributor(), info.feeDistributor, "token feeDistributor mismatch");
        assertEq(token.presaleManager(), info.presaleManager, "token presaleManager mismatch");
        assertTrue(token.isExempt(info.presaleManager), "presaleManager should be exempt");
        assertTrue(token.isExempt(info.feeDistributor), "feeDistributor should be exempt");
        assertTrue(token.isExempt(info.lpStaking), "lpStaking should be exempt");
        assertTrue(token.isExempt(boardwalkLPManager), "boardwalkLPManager should be exempt");

        // Verify launch count
        assertEq(factory.launchCount(), 1, "launchCount should be 1");
    }

    function test_CreateLaunch_ExpressPath_NoVestingClone() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);

        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);
        assertEq(info.vestingStream, address(0), "vestingStream should be zero for Express");
    }

    function test_CreateLaunch_ExpressPath_PresalePercentForcedTo5000() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();
        config.presalePercent = 3000; // Should be ignored, forced to 5000

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);

        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);
        PresaleManager presale = PresaleManager(info.presaleManager);
        assertEq(presale.presalePercent(), 5000, "presalePercent should be forced to 5000");
    }

    // ============ CreateLaunch - Advanced Path ============

    function test_CreateLaunch_AdvancedPath_Success() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);

        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);
        assertEq(uint256(info.path), uint256(LaunchFactory.LaunchPath.ADVANCED), "path mismatch");
        // No vesting recipients in default config, so vestingStream should be zero
        assertEq(info.vestingStream, address(0), "vestingStream should be zero without vesting recipients");

        PresaleManager presale = PresaleManager(info.presaleManager);
        assertEq(presale.presalePercent(), config.presalePercent, "presalePercent mismatch");
    }

    function test_CreateLaunch_AdvancedPath_WithReferrer() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.referrer = referrer;

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);

        LaunchFactory.LaunchInfo memory infoRef = _getLaunchInfo(tokenAddr);
        IFeeDistributor feeDistributor = IFeeDistributor(infoRef.feeDistributor);
        // Verify referrer is set (check via claimableAmount or other view function)
        // Note: We can't directly check referrer address, but we can verify initialization succeeded
        assertTrue(address(feeDistributor) != address(0), "feeDistributor should be initialized");
    }

    function test_CreateLaunch_AdvancedPath_WithVesting() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        // pp < 5000 to satisfy the vesting-allowed branch.
        config.presalePercent = 4500;
        config.vestingRecipients = new address[](2);
        config.vestingRecipients[0] = vestingRecipient1;
        config.vestingRecipients[1] = vestingRecipient2;
        config.vestingPercents = new uint256[](2);
        config.vestingPercents[0] = 6000;
        config.vestingPercents[1] = 4000;
        config.vestingLabels = new string[](2);
        config.vestingLabels[0] = "v0";
        config.vestingLabels[1] = "v1";

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);

        LaunchFactory.LaunchInfo memory info = _getLaunchInfo(tokenAddr);
        assertTrue(info.vestingStream != address(0), "vestingStream should be set");
    }

    // ============ CreateLaunch - BMX Burn ============

    function test_CreateLaunch_BmxBurnZero_SkipsBurn() public {
        // Set BMX burn to zero
        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(0)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetBmxBurn(0);

        // Create launch without BMX balance
        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);

        // Verify launch succeeded
        LaunchFactory.LaunchInfo memory lInfo = _getLaunchInfo(tokenAddr);
        assertTrue(lInfo.token != address(0), "Launch should succeed");
    }

    function test_CreateLaunch_BmxBurn_TransfersToDeadAddress() public {
        uint256 burnAmount = 50e18;
        bmx.mint(issuer, burnAmount);
        vm.prank(issuer);
        bmx.approve(address(factory), burnAmount);

        // Set custom burn amount
        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(burnAmount)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetBmxBurn(burnAmount);

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();

        vm.prank(issuer);
        factory.createLaunch(config);

        assertEq(bmx.balanceOf(issuer), 0, "Issuer BMX should be burned");
        assertEq(
            bmx.balanceOf(address(0x000000000000000000000000000000000000dEaD)),
            burnAmount,
            "BMX should be in dead address"
        );
    }

    function test_RevertWhen_CreateLaunch_BmxNotApproved() public {
        // Don't approve BMX - OZ ERC20 reverts with InsufficientAllowance
        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();

        vm.prank(issuer);
        vm.expectRevert(); // Will revert with ERC20InsufficientAllowance
        factory.createLaunch(config);
    }

    function test_RevertWhen_CreateLaunch_InsufficientBmxBalance() public {
        // Mint less than required
        bmx.mint(issuer, DEFAULT_BMX_BURN - 1);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();

        vm.prank(issuer);
        vm.expectRevert();
        factory.createLaunch(config);
    }

    // ============ Validation - Express Path ============

    function test_RevertWhen_CreateLaunch_ExpressPath_WithReferrer() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();
        config.referrer = referrer;

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.ReferrerNotAllowedOnExpressPath.selector);
        factory.createLaunch(config);
    }

    function test_RevertWhen_CreateLaunch_ExpressPath_WithVesting() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();
        config.vestingRecipients = new address[](1);
        config.vestingRecipients[0] = vestingRecipient1;
        config.vestingPercents = new uint256[](1);
        config.vestingPercents[0] = BPS_DENOMINATOR;
        config.vestingLabels = new string[](1);

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.VestingNotAllowedOnExpressPath.selector);
        factory.createLaunch(config);
    }

    function test_RevertWhen_CreateLaunch_ExpressPath_NotOneFeeRecipient() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();
        config.issuerFeeRecipients = new address[](2);
        config.issuerFeeRecipients[0] = feeRecipient1;
        config.issuerFeeRecipients[1] = feeRecipient2;
        config.issuerFeeSplits = new uint256[](2);
        config.issuerFeeSplits[0] = 5000;
        config.issuerFeeSplits[1] = 5000;
        config.issuerFeeLabels = new string[](2);

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.ExpressRequiresOneFeeRecipient.selector);
        factory.createLaunch(config);
    }

    // ============ Validation - Advanced Path ============

    function test_RevertWhen_CreateLaunch_AdvancedPath_PresalePercentTooLow() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.presalePercent = MIN_PRESALE_PERCENT - 1;

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.InvalidPresalePercent.selector, MIN_PRESALE_PERCENT - 1));
        factory.createLaunch(config);
    }

    function test_RevertWhen_CreateLaunch_AdvancedPath_PresalePercentTooHigh() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.presalePercent = MAX_PRESALE_PERCENT + 1;

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.InvalidPresalePercent.selector, MAX_PRESALE_PERCENT + 1));
        factory.createLaunch(config);
    }

    function test_RevertWhen_CreateLaunch_AdvancedPath_PresalePercentNotDivisibleBy500() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.presalePercent = 3001; // Not divisible by 500

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.PresalePercentNotDivisibleBy5.selector);
        factory.createLaunch(config);
    }

    function test_RevertWhen_CreateLaunch_AdvancedPath_PresaleBelow5000WithoutVestingRecipients() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.presalePercent = 4500;
        config.vestingRecipients = new address[](0);
        config.vestingPercents = new uint256[](0);

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.IssuerVestingRecipientsRequired.selector);
        factory.createLaunch(config);
    }

    /// @notice Advanced launches at `pp == 5000` have a zero issuer-vesting bucket; vesting
    ///         recipients must be rejected to avoid deploying an uninitializable VestingStream.
    function test_RevertWhen_CreateLaunch_AdvancedPath_FullPresaleWithVestingRecipients() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.presalePercent = 5000;
        address[] memory vr = new address[](1);
        vr[0] = vestingRecipient1;
        config.vestingRecipients = vr;
        uint256[] memory vp = new uint256[](1);
        vp[0] = BPS_DENOMINATOR;
        config.vestingPercents = vp;
        config.vestingLabels = new string[](1);

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.VestingNotAllowedAtFullPresale.selector);
        factory.createLaunch(config);
    }

    function test_CreateLaunch_AdvancedPath_PresalePercentDivisibleBy500() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.presalePercent = 3500; // Divisible by 500

        // presalePercent < 5000 requires vesting recipients
        address[] memory vr = new address[](1);
        vr[0] = makeAddr("vestee");
        config.vestingRecipients = vr;
        uint256[] memory vp = new uint256[](1);
        vp[0] = 10000;
        config.vestingPercents = vp;
        config.vestingLabels = new string[](1);

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);

        assertTrue(tokenAddr != address(0), "Launch should succeed");
    }

    function test_RevertWhen_CreateLaunch_AdvancedPath_TooManyVestingRecipients() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        // pp < 5000 to satisfy the vesting-allowed branch.
        config.presalePercent = 4500;
        uint256 count = 6;
        config.vestingRecipients = new address[](count);
        config.vestingPercents = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            config.vestingRecipients[i] = makeAddr(string(abi.encode("vesting", i)));
        }
        config.vestingLabels = new string[](count);
        config.vestingPercents[0] = 2000;
        config.vestingPercents[1] = 2000;
        config.vestingPercents[2] = 2000;
        config.vestingPercents[3] = 2000;
        config.vestingPercents[4] = 1000;
        config.vestingPercents[5] = 1000;

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.TooManyRecipients.selector, count));
        factory.createLaunch(config);
    }

    function test_RevertWhen_CreateLaunch_AdvancedPath_TooManyFeeRecipients() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        uint256 count = 5;
        config.issuerFeeRecipients = new address[](count);
        config.issuerFeeSplits = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            config.issuerFeeRecipients[i] = makeAddr(string(abi.encode("fee", i)));
            config.issuerFeeSplits[i] = 2000;
        }
        config.issuerFeeLabels = new string[](count);

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.TooManyRecipients.selector, count));
        factory.createLaunch(config);
    }

    function test_CreateLaunch_AdvancedPath_FourFeeRecipients() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.issuerFeeRecipients = new address[](4);
        config.issuerFeeSplits = new uint256[](4);
        config.issuerFeeRecipients[0] = feeRecipient1;
        config.issuerFeeRecipients[1] = feeRecipient2;
        config.issuerFeeRecipients[2] = feeRecipient3;
        config.issuerFeeRecipients[3] = feeRecipient4;
        config.issuerFeeSplits[0] = 4000;
        config.issuerFeeSplits[1] = 3000;
        config.issuerFeeSplits[2] = 2000;
        config.issuerFeeSplits[3] = 1000;
        config.issuerFeeLabels = new string[](4);

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);
        assertTrue(tokenAddr != address(0), "Launch with 4 fee recipients should succeed");
    }

    function test_CreateLaunch_AdvancedPath_FourVestingRecipients() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.presalePercent = 3000;
        config.vestingRecipients = new address[](4);
        config.vestingPercents = new uint256[](4);
        config.vestingRecipients[0] = vestingRecipient1;
        config.vestingRecipients[1] = vestingRecipient2;
        config.vestingRecipients[2] = vestingRecipient3;
        config.vestingRecipients[3] = vestingRecipient4;
        config.vestingPercents[0] = 4000;
        config.vestingPercents[1] = 3000;
        config.vestingPercents[2] = 2000;
        config.vestingPercents[3] = 1000;
        config.vestingLabels = new string[](4);

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);
        assertTrue(tokenAddr != address(0), "Launch with 4 vesting recipients should succeed");
    }

    function test_CreateLaunch_AdvancedPath_FiveVestingRecipients() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.presalePercent = 3000;
        config.vestingRecipients = new address[](5);
        config.vestingPercents = new uint256[](5);
        config.vestingRecipients[0] = vestingRecipient1;
        config.vestingRecipients[1] = vestingRecipient2;
        config.vestingRecipients[2] = vestingRecipient3;
        config.vestingRecipients[3] = vestingRecipient4;
        config.vestingRecipients[4] = vestingRecipient5;
        config.vestingPercents[0] = 3000;
        config.vestingPercents[1] = 2500;
        config.vestingPercents[2] = 2000;
        config.vestingPercents[3] = 1500;
        config.vestingPercents[4] = 1000;
        config.vestingLabels = new string[](5);

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);
        assertTrue(tokenAddr != address(0), "Launch with 5 vesting recipients should succeed");
    }

    function test_RevertWhen_CreateLaunch_AdvancedPath_ZeroFeeRecipients() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.issuerFeeRecipients = new address[](0);
        config.issuerFeeSplits = new uint256[](0);
        config.issuerFeeLabels = new string[](0);

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.TooManyRecipients.selector, 0));
        factory.createLaunch(config);
    }

    // ============ Validation - Array Lengths ============

    function test_RevertWhen_CreateLaunch_FeeRecipientsSplitsLengthMismatch() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();
        config.issuerFeeRecipients = new address[](1);
        config.issuerFeeRecipients[0] = feeRecipient1;
        config.issuerFeeSplits = new uint256[](2); // Mismatch
        config.issuerFeeSplits[0] = 5000;
        config.issuerFeeSplits[1] = 5000;

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.ArrayLengthMismatch.selector);
        factory.createLaunch(config);
    }

    function test_RevertWhen_CreateLaunch_VestingRecipientsPercentsLengthMismatch() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.vestingRecipients = new address[](2);
        config.vestingRecipients[0] = vestingRecipient1;
        config.vestingRecipients[1] = vestingRecipient2;
        config.vestingPercents = new uint256[](1); // Mismatch
        config.vestingPercents[0] = BPS_DENOMINATOR;
        config.vestingLabels = new string[](2);

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.ArrayLengthMismatch.selector);
        factory.createLaunch(config);
    }

    function test_RevertWhen_CreateLaunch_FeeRecipientsLabelsLengthMismatch() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();
        config.issuerFeeLabels = new string[](2); // 2 labels but 1 recipient

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.ArrayLengthMismatch.selector);
        factory.createLaunch(config);
    }

    function test_RevertWhen_CreateLaunch_VestingRecipientsLabelsLengthMismatch() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.vestingRecipients = new address[](2);
        config.vestingRecipients[0] = vestingRecipient1;
        config.vestingRecipients[1] = vestingRecipient2;
        config.vestingPercents = new uint256[](2);
        config.vestingPercents[0] = 5000;
        config.vestingPercents[1] = 5000;
        config.vestingLabels = new string[](1); // 1 label but 2 recipients

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.ArrayLengthMismatch.selector);
        factory.createLaunch(config);
    }

    // ============ Validation - Fee Splits ============

    function test_RevertWhen_CreateLaunch_FeeSplitsNotSumTo10000() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();
        config.issuerFeeSplits[0] = 5000; // Should be 10000

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.InvalidSplitsSum.selector);
        factory.createLaunch(config);
    }

    function test_RevertWhen_CreateLaunch_FeeSplitsSumExceeds10000() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.issuerFeeSplits[0] = 6000;
        config.issuerFeeSplits[1] = 5000; // Sum = 11000

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.InvalidSplitsSum.selector);
        factory.createLaunch(config);
    }

    function test_RevertWhen_CreateLaunch_FeeRecipientZeroAddress() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();
        config.issuerFeeRecipients[0] = address(0);

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        factory.createLaunch(config);
    }

    // ============ Validation - Vesting Percents ============

    function test_RevertWhen_CreateLaunch_VestingPercentsNotSumTo10000() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        // pp < 5000 to satisfy the vesting-allowed branch.
        config.presalePercent = 4500;
        config.vestingRecipients = new address[](2);
        config.vestingRecipients[0] = vestingRecipient1;
        config.vestingRecipients[1] = vestingRecipient2;
        config.vestingPercents = new uint256[](2);
        config.vestingPercents[0] = 6000;
        config.vestingPercents[1] = 3000; // Sum = 9000, should be 10000
        config.vestingLabels = new string[](2);

        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.InvalidSplitsSum.selector);
        factory.createLaunch(config);
    }

    // ============ Multiple Launches ============

    function test_CreateLaunch_MultipleLaunches_DifferentAddresses() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN * 2);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN * 2);

        LaunchFactory.LaunchConfig memory config1 = _buildExpressConfig();
        config1.name = "Token1";
        config1.ticker = "TKN1";

        LaunchFactory.LaunchConfig memory config2 = _buildExpressConfig();
        config2.name = "Token2";
        config2.ticker = "TKN2";

        vm.prank(issuer);
        address token1 = factory.createLaunch(config1);

        vm.prank(issuer);
        address token2 = factory.createLaunch(config2);

        assertTrue(token1 != token2, "Tokens should be different");
        assertEq(factory.launchCount(), 2, "launchCount should be 2");

        LaunchFactory.LaunchInfo memory info1 = _getLaunchInfo(token1);
        LaunchFactory.LaunchInfo memory info2 = _getLaunchInfo(token2);

        assertTrue(info1.feeDistributor != info2.feeDistributor, "Fee distributors should be different");
        assertTrue(info1.presaleManager != info2.presaleManager, "Presale managers should be different");
        assertTrue(info1.lpStaking != info2.lpStaking, "LP staking should be different");
    }

    // ============ Timelocked Admin Functions ============

    function test_SignalSetBmxBurn_Success() public {
        uint256 newAmount = 200e18;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(newAmount)));

        (bool isPending, uint256 executeTime, uint256 expiresAt) =
            factory.getPendingChange(factory.ACTION_SET_BMX_BURN());

        assertTrue(isPending, "Change should be pending");
        assertEq(executeTime, block.timestamp + TIMELOCK_DELAY, "executeTime mismatch");
        assertEq(expiresAt, executeTime + TIMELOCK_EXPIRY, "expiresAt mismatch");
    }

    function test_ExecuteSetBmxBurn_Success() public {
        uint256 newAmount = 200e18;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(newAmount)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectEmit(true, false, false, true);
        emit BmxBurnAmountChanged(DEFAULT_BMX_BURN, newAmount);

        factory.executeSetBmxBurn(newAmount);

        assertEq(factory.bmxBurnAmount(), newAmount, "bmxBurnAmount should be updated");
    }

    function test_RevertWhen_ExecuteSetBmxBurn_BeforeDelay() public {
        uint256 newAmount = 200e18;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(newAmount)));

        // Try to execute immediately
        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockTooEarly.selector, block.timestamp + TIMELOCK_DELAY));
        factory.executeSetBmxBurn(newAmount);
    }

    function test_RevertWhen_ExecuteSetBmxBurn_AfterExpiry() public {
        uint256 newAmount = 200e18;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(newAmount)));

        // Warp past delay + expiry
        vm.warp(block.timestamp + TIMELOCK_DELAY + TIMELOCK_EXPIRY + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Timelocked.TimelockExpired.selector,
                block.timestamp - 1 // expiredAt
            )
        );
        factory.executeSetBmxBurn(newAmount);
    }

    function test_RevertWhen_ExecuteSetBmxBurn_WrongDataHash() public {
        uint256 newAmount = 200e18;
        uint256 wrongAmount = 300e18;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(newAmount)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(Timelocked.TimelockDataMismatch.selector);
        factory.executeSetBmxBurn(wrongAmount);
    }

    function test_RevertWhen_ExecuteSetBmxBurn_NotSignaled() public {
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        factory.executeSetBmxBurn(200e18);
    }

    // ============ Per-Action Burn (Generic Renounce) ============

    function test_SignalBurnAction_Success() public {
        bytes32 action = factory.ACTION_SET_BMX_BURN();
        vm.prank(owner);
        factory.signalBurnAction(action);

        (bool isPending,,) = factory.getPendingBurn(action);
        assertTrue(isPending, "Burn should be pending");
    }

    function test_ExecuteBurnAction_Success() public {
        bytes32 action = factory.ACTION_SET_BMX_BURN();
        vm.prank(owner);
        factory.signalBurnAction(action);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeBurnAction(action);

        assertTrue(factory.isActionBurned(action), "ACTION_SET_BMX_BURN should be burned");
    }

    function test_ExecuteBurnAction_CancelsPendingChange() public {
        bytes32 action = factory.ACTION_SET_BMX_BURN();
        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(50e18)));

        vm.prank(owner);
        factory.signalBurnAction(action);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeBurnAction(action);

        (bool isPending,,) = factory.getPendingChange(action);
        assertFalse(isPending, "Pending change should be cleared by burn");
    }

    function test_RevertWhen_SignalBurnedAction() public {
        bytes32 action = factory.ACTION_SET_BMX_BURN();
        vm.prank(owner);
        factory.signalBurnAction(action);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeBurnAction(action);

        vm.expectRevert(abi.encodeWithSelector(Timelocked.ActionIsBurned.selector, action));
        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(100e18)));
    }

    function test_RevertWhen_ExecuteBurnedAction() public {
        bytes32 action = factory.ACTION_SET_BMX_BURN();
        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(100e18)));

        vm.prank(owner);
        factory.signalBurnAction(action);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeBurnAction(action);

        vm.expectRevert(abi.encodeWithSelector(Timelocked.ActionIsBurned.selector, action));
        factory.executeSetBmxBurn(100e18);
    }

    function test_RevertWhen_BurnAlreadyBurned() public {
        bytes32 action = factory.ACTION_SET_BMX_BURN();
        vm.prank(owner);
        factory.signalBurnAction(action);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeBurnAction(action);

        vm.expectRevert(Timelocked.ActionAlreadyBurned.selector);
        vm.prank(owner);
        factory.signalBurnAction(action);
    }

    function test_CancelBurnAction() public {
        bytes32 action = factory.ACTION_SET_BMX_BURN();
        vm.prank(owner);
        factory.signalBurnAction(action);

        vm.prank(owner);
        factory.cancelBurnAction(action);

        (bool isPending,,) = factory.getPendingBurn(action);
        assertFalse(isPending, "Burn should be canceled");
        assertFalse(factory.isActionBurned(action), "Should not be burned after cancel");
    }

    function test_RevertWhen_SignalBurnAction_NotOwner() public {
        bytes32 action = factory.ACTION_SET_BMX_BURN();
        vm.expectRevert();
        factory.signalBurnAction(action);
    }

    function test_RevertWhen_ExecuteBurnAction_TooEarly() public {
        bytes32 action = factory.ACTION_SET_BMX_BURN();
        vm.prank(owner);
        factory.signalBurnAction(action);

        vm.expectRevert();
        factory.executeBurnAction(action);
    }

    function test_RevertWhen_ExecuteBurnAction_Expired() public {
        bytes32 action = factory.ACTION_SET_BMX_BURN();
        vm.prank(owner);
        factory.signalBurnAction(action);

        vm.warp(block.timestamp + TIMELOCK_DELAY + 7 days + 1);
        vm.expectRevert();
        factory.executeBurnAction(action);
    }

    function testFuzz_BurnAnyAction(
        bytes32 action
    ) public {
        vm.prank(owner);
        factory.signalBurnAction(action);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeBurnAction(action);

        assertTrue(factory.isActionBurned(action), "Action should be burned");
    }

    function test_RevertWhen_SignalAction_CannotBypassBurnDelay() public {
        bytes32 action = factory.ACTION_SET_BMX_BURN();
        bytes32 oldBurnKey = keccak256(abi.encode("BURN", action));
        bytes32 dataHash = keccak256(abi.encode(action));

        vm.prank(owner);
        factory.signalAction(oldBurnKey, dataHash);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        factory.executeBurnAction(action);
    }

    function test_SignalSetGraduationExpress_Success() public {
        uint256 newThreshold = 20 ether;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_GRADUATION_EXPRESS, keccak256(abi.encode(newThreshold)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetGraduation(LaunchFactory.LaunchPath.EXPRESS, newThreshold);

        assertEq(factory.graduationExpress(), newThreshold, "graduationExpress should be updated");
    }

    function test_SignalSetGraduationAdvanced_Success() public {
        uint256 newThreshold = 20 ether;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_GRADUATION_ADVANCED, keccak256(abi.encode(newThreshold)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetGraduation(LaunchFactory.LaunchPath.ADVANCED, newThreshold);

        assertEq(factory.graduationAdvanced(), newThreshold, "graduationAdvanced should be updated");
    }

    function test_SignalSetFeeDefaults_Success() public {
        // Main factory has INTEGRATOR_BPS=2 (immutable). New defaults must satisfy
        // total == issuer + boardwalk + incentive + 2.
        LaunchFactory.FeeBpsDefaults memory newDefaults = LaunchFactory.FeeBpsDefaults({
            issuer: 40, // 0.40%
            boardwalk: 35, // 0.35%
            incentive: 15, // 0.15%
            referrer: 10, // 0.10% (carved from boardwalk)
            total: 92 // 0.92% = 40+35+15+2 (integrator immutable, referrer not in total)
        });

        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_DEFAULTS, keccak256(abi.encode(newDefaults)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetFeeDefaults(newDefaults);

        (
            uint256 issuerBps,
            uint256 boardwalkBps,
            uint256 incentiveBps,
            uint256 referrerBps,
            ,
            uint256 totalBps
        ) = factory.currentFeeBps();
        assertEq(issuerBps, newDefaults.issuer, "issuer BPS mismatch");
        assertEq(boardwalkBps, newDefaults.boardwalk, "boardwalk BPS mismatch");
        assertEq(incentiveBps, newDefaults.incentive, "incentive BPS mismatch");
        assertEq(referrerBps, newDefaults.referrer, "referrer BPS mismatch");
        assertEq(totalBps, newDefaults.total, "total BPS mismatch");
    }

    // ============ Access Control ============

    function test_RevertWhen_SignalSetBmxBurn_NotOwner() public {
        vm.expectRevert();
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(200e18)));
    }

    function test_RevertWhen_SignalSetGraduationExpress_NotOwner() public {
        vm.expectRevert();
        factory.signalAction(ACTION_SET_GRADUATION_EXPRESS, keccak256(abi.encode(20 ether)));
    }

    function test_RevertWhen_SignalSetFeeDefaults_NotOwner() public {
        LaunchFactory.FeeBpsDefaults memory newDefaults = LaunchFactory.FeeBpsDefaults({
            issuer: 40, // valid per-component values for cleanliness
            boardwalk: 35,
            incentive: 15,
            referrer: 5,
            total: 90
        });

        vm.expectRevert();
        factory.signalAction(ACTION_SET_FEE_DEFAULTS, keccak256(abi.encode(newDefaults)));
    }

    // ============ Fuzz Tests ============

    function testFuzz_CreateLaunch_ExpressPath(
        uint256 bmxAmount
    ) public {
        bmxAmount = bound(bmxAmount, 0, 200e18);

        // Set BMX burn amount
        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(bmxAmount)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetBmxBurn(bmxAmount);

        if (bmxAmount > 0) {
            bmx.mint(issuer, bmxAmount);
            vm.prank(issuer);
            bmx.approve(address(factory), bmxAmount);
        }

        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);

        assertTrue(tokenAddr != address(0), "Token should be deployed");
        LaunchFactory.LaunchInfo memory fInfo = _getLaunchInfo(tokenAddr);
        assertEq(fInfo.issuer, issuer, "Issuer mismatch");

        if (bmxAmount > 0) {
            assertEq(bmx.balanceOf(issuer), 0, "BMX should be burned");
            assertEq(
                bmx.balanceOf(address(0x000000000000000000000000000000000000dEaD)),
                bmxAmount,
                "BMX should be in dead address"
            );
        }
    }

    function testFuzz_CreateLaunch_AdvancedPath_PresalePercent(
        uint256 presalePercent
    ) public {
        presalePercent = bound(presalePercent, MIN_PRESALE_PERCENT, MAX_PRESALE_PERCENT);
        // Ensure divisible by 500
        presalePercent = (presalePercent / 500) * 500;
        if (presalePercent < MIN_PRESALE_PERCENT) presalePercent = MIN_PRESALE_PERCENT;

        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.presalePercent = presalePercent;

        // if presalePercent < 5000, vesting recipients are required
        if (presalePercent < 5000) {
            address[] memory vr = new address[](1);
            vr[0] = makeAddr("vestee");
            config.vestingRecipients = vr;
            uint256[] memory vp = new uint256[](1);
            vp[0] = 10000; // 100% to single vestee
            config.vestingPercents = vp;
            config.vestingLabels = new string[](1);
        }

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);

        LaunchFactory.LaunchInfo memory fInfo = _getLaunchInfo(tokenAddr);
        PresaleManager presale = PresaleManager(fInfo.presaleManager);
        assertEq(presale.presalePercent(), presalePercent, "presalePercent mismatch");
    }

    function testFuzz_CreateLaunch_FeeSplits(
        uint256 split1,
        uint256 split2
    ) public {
        split1 = bound(split1, 1, BPS_DENOMINATOR - 1);
        split2 = BPS_DENOMINATOR - split1;

        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        LaunchFactory.LaunchConfig memory config = _buildAdvancedConfig();
        config.issuerFeeRecipients = new address[](2);
        config.issuerFeeRecipients[0] = feeRecipient1;
        config.issuerFeeRecipients[1] = feeRecipient2;
        config.issuerFeeSplits = new uint256[](2);
        config.issuerFeeSplits[0] = split1;
        config.issuerFeeSplits[1] = split2;

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);

        assertTrue(tokenAddr != address(0), "Launch should succeed");
    }

    // ============ Helpers ============

    function _getLaunchInfo(
        address tokenAddr
    ) internal view returns (LaunchFactory.LaunchInfo memory info) {
        (
            info.token,
            info.feeDistributor,
            info.presaleManager,
            info.vestingStream,
            info.lpStaking,
            info.issuer,
            info.path,
            info.createdAt
        ) = factory.launches(tokenAddr);
    }

    function _buildExpressConfig() internal view returns (LaunchFactory.LaunchConfig memory) {
        address[] memory feeRecipients = new address[](1);
        feeRecipients[0] = feeRecipient1;

        uint256[] memory feeSplits = new uint256[](1);
        feeSplits[0] = BPS_DENOMINATOR;

        string[] memory feeLabels = new string[](1);
        feeLabels[0] = "issuer";

        return LaunchFactory.LaunchConfig({
            name: "Test Token",
            ticker: "TEST",
            category: "DeFi",
            description: "Test token description",
            path: LaunchFactory.LaunchPath.EXPRESS,
            presalePercent: 5000, // Ignored for Express, but required
            vestingRecipients: new address[](0),
            vestingPercents: new uint256[](0),
            vestingLabels: new string[](0),
            referrer: address(0),
            issuerFeeRecipients: feeRecipients,
            issuerFeeSplits: feeSplits,
            issuerFeeLabels: feeLabels
        });
    }

    function _buildAdvancedConfig() internal view returns (LaunchFactory.LaunchConfig memory) {
        address[] memory feeRecipients = new address[](2);
        feeRecipients[0] = feeRecipient1;
        feeRecipients[1] = feeRecipient2;

        uint256[] memory feeSplits = new uint256[](2);
        feeSplits[0] = 6000;
        feeSplits[1] = 4000;

        string[] memory feeLabels = new string[](2);
        feeLabels[0] = "feeA";
        feeLabels[1] = "feeB";

        return LaunchFactory.LaunchConfig({
            name: "Advanced Token",
            ticker: "ADV",
            category: "DeFi",
            description: "Advanced token description",
            path: LaunchFactory.LaunchPath.ADVANCED,
            presalePercent: 5000, // >= 5000 so no vesting recipients required
            vestingRecipients: new address[](0),
            vestingPercents: new uint256[](0),
            vestingLabels: new string[](0),
            referrer: address(0),
            issuerFeeRecipients: feeRecipients,
            issuerFeeSplits: feeSplits,
            issuerFeeLabels: feeLabels
        });
    }

    /// @dev Deploy a new LaunchFactory with custom fee BPS defaults (reuses all other setUp params).
    ///      Uses integratorCollector==address(0) and INTEGRATOR_BPS==0 — callers must construct
    ///      `feeBps.total` accordingly (sum of issuer + boardwalk + incentive).
    function _deployFactoryWith(
        LaunchFactory.FeeBpsDefaults memory feeBps
    ) internal returns (LaunchFactory) {
        return new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(0),
                integratorBps: 0,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: feeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );
    }

    /// @dev Deploy a new LaunchFactory with integratorCollector==address(0) and INTEGRATOR_BPS==0.
    function _deployFactoryWithoutIntegrator() internal returns (LaunchFactory f) {
        LaunchFactory.FeeBpsDefaults memory noIntegrator = LaunchFactory.FeeBpsDefaults({
            issuer: 40,
            boardwalk: 47,
            incentive: 28,
            referrer: 5,
            total: 115
        });
        f = new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(0),
                integratorBps: 0,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: noIntegrator,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );
    }

    /// @dev Signal + warp + execute fee defaults via timelock on the main factory
    function _timelockSetFeeDefaults(
        LaunchFactory.FeeBpsDefaults memory d
    ) internal {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_DEFAULTS, keccak256(abi.encode(d)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
    }

    // ================================================================
    //  COVERAGE GAP TESTS — Duration Setters (with timelock warps)
    // ================================================================

    function test_SignalExecuteSetExpressDuration_Success() public {
        uint256 newDuration = 12 hours;
        uint256 t = block.timestamp;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_EXPRESS_DURATION, keccak256(abi.encode(newDuration)));

        t += TIMELOCK_DELAY;
        vm.warp(t);

        factory.executeSetDuration(LaunchFactory.LaunchPath.EXPRESS, newDuration);
        assertEq(factory.expressDuration(), newDuration, "Express duration should be updated");
    }

    function test_RevertWhen_SetExpressDuration_Zero() public {
        uint256 t = block.timestamp;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_EXPRESS_DURATION, keccak256(abi.encode(0)));

        t += TIMELOCK_DELAY;
        vm.warp(t);

        vm.expectRevert(LaunchFactory.InvalidDuration.selector);
        factory.executeSetDuration(LaunchFactory.LaunchPath.EXPRESS, 0);
    }

    function test_SignalExecuteSetAdvancedDuration_Success() public {
        uint256 newDuration = 5 days;
        uint256 t = block.timestamp;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_ADVANCED_DURATION, keccak256(abi.encode(newDuration)));

        t += TIMELOCK_DELAY;
        vm.warp(t);

        factory.executeSetDuration(LaunchFactory.LaunchPath.ADVANCED, newDuration);
        assertEq(factory.advancedDuration(), newDuration, "Advanced duration should be updated");
    }

    function test_RevertWhen_SetAdvancedDuration_TooShort() public {
        uint256 t = block.timestamp;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_ADVANCED_DURATION, keccak256(abi.encode(1 days)));

        t += TIMELOCK_DELAY;
        vm.warp(t);

        vm.expectRevert(LaunchFactory.InvalidDuration.selector);
        factory.executeSetDuration(LaunchFactory.LaunchPath.ADVANCED, 1 days);
    }

    function test_RevertWhen_SetAdvancedDuration_TooLong() public {
        uint256 t = block.timestamp;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_ADVANCED_DURATION, keccak256(abi.encode(15 days)));

        t += TIMELOCK_DELAY;
        vm.warp(t);

        vm.expectRevert(LaunchFactory.InvalidDuration.selector);
        factory.executeSetDuration(LaunchFactory.LaunchPath.ADVANCED, 15 days);
    }

    // ================================================================
    //  COVERAGE GAP TESTS — BMX Burn Skip + Fee Validation
    // ================================================================

    function test_CreateLaunch_BmxBurnZero_SkipsBurnPath() public {
        // Set BMX burn to 0 via timelock
        uint256 t = block.timestamp;
        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(0)));
        t += TIMELOCK_DELAY;
        vm.warp(t);
        factory.executeSetBmxBurn(0);

        // Create launch without needing any BMX
        LaunchFactory.LaunchConfig memory config = _buildExpressConfig();
        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(config);

        assertTrue(tokenAddr != address(0), "Launch should succeed without BMX burn");
    }

    function test_RevertWhen_FeeDefaults_SumMismatch() public {
        uint256 t = block.timestamp;
        LaunchFactory.FeeBpsDefaults memory bad = LaunchFactory.FeeBpsDefaults({
            issuer: 30,
            boardwalk: 30,
            incentive: 20,
            referrer: 5,
            total: 999 // sum = 82 (incl. INTEGRATOR_BPS=2), total = 999 → reverts InvalidFeeDefaults
        });

        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_DEFAULTS, keccak256(abi.encode(bad)));
        t += TIMELOCK_DELAY;
        vm.warp(t);

        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        factory.executeSetFeeDefaults(bad);
    }

    function test_RevertWhen_FeeDefaults_IssuerAboveMax() public {
        uint256 t = block.timestamp;
        // issuer 81 exceeds max of 80 (step 2 in _validateFeeDefaults)
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 81, boardwalk: 30, incentive: 20, referrer: 5, total: 131});

        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_DEFAULTS, keccak256(abi.encode(bad)));
        t += TIMELOCK_DELAY;
        vm.warp(t);

        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        factory.executeSetFeeDefaults(bad);
    }

    function test_RevertWhen_FeeDefaults_ReferrerAboveMax() public {
        uint256 t = block.timestamp;
        // referrer 11 exceeds max of 10 (step 5 in _validateFeeDefaults)
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 30, boardwalk: 30, incentive: 20, referrer: 11, total: 80});

        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_DEFAULTS, keccak256(abi.encode(bad)));
        t += TIMELOCK_DELAY;
        vm.warp(t);

        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        factory.executeSetFeeDefaults(bad);
    }

    function test_RevertWhen_FeeDefaults_AllZero() public {
        uint256 t = block.timestamp;
        // issuer 0 is below min of 10 (step 2 in _validateFeeDefaults)
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 0, boardwalk: 0, incentive: 0, referrer: 0, total: 0});

        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_DEFAULTS, keccak256(abi.encode(bad)));
        t += TIMELOCK_DELAY;
        vm.warp(t);

        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        factory.executeSetFeeDefaults(bad);
    }

    // ================================================================
    //  PHASE 2 — Fix 1: Per-Component Fee Bounds (Constructor Path)
    // ================================================================

    function test_RevertWhen_Constructor_IssuerBelowMin() public {
        // issuer 9 < min 10
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 9, boardwalk: 30, incentive: 20, referrer: 5, total: 59});
        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        _deployFactoryWith(bad);
    }

    function test_RevertWhen_Constructor_IssuerAboveMax() public {
        // issuer 81 > max 80
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 81, boardwalk: 30, incentive: 20, referrer: 5, total: 131});
        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        _deployFactoryWith(bad);
    }

    function test_RevertWhen_Constructor_BoardwalkBelowMin() public {
        // boardwalk 9 < min 10
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 30, boardwalk: 9, incentive: 20, referrer: 5, total: 59});
        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        _deployFactoryWith(bad);
    }

    function test_RevertWhen_Constructor_BoardwalkAboveMax() public {
        // boardwalk 51 > max 50
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 30, boardwalk: 51, incentive: 20, referrer: 5, total: 101});
        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        _deployFactoryWith(bad);
    }

    function test_RevertWhen_Constructor_IncentiveAboveMax() public {
        // incentive 51 > max 50
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 30, boardwalk: 30, incentive: 51, referrer: 5, total: 111});
        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        _deployFactoryWith(bad);
    }

    function test_RevertWhen_Constructor_ReferrerAboveMax() public {
        // referrer 11 > max 10
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 30, boardwalk: 30, incentive: 20, referrer: 11, total: 80});
        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        _deployFactoryWith(bad);
    }

    function test_RevertWhen_Constructor_SumMismatch() public {
        // total 999 != issuer+boardwalk+incentive = 80
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 30, boardwalk: 30, incentive: 20, referrer: 5, total: 999});
        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        _deployFactoryWith(bad);
    }

    function test_RevertWhen_Constructor_BmxBurnAboveMax() public {
        uint256 invalidBurnAmount = 200e18 + 1;

        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.BmxBurnOutOfRange.selector, invalidBurnAmount));
        new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(integratorCollector),
                integratorBps: 2,
                bmxBurnAmount: invalidBurnAmount,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: defaultFeeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );
    }

    function test_Constructor_FeeDefaults_AtMinBoundaries() public {
        // All components at their minimum valid values; uses _deployFactoryWith (INTEGRATOR_BPS=0).
        LaunchFactory.FeeBpsDefaults memory minFees =
            LaunchFactory.FeeBpsDefaults({issuer: 10, boardwalk: 10, incentive: 0, referrer: 0, total: 20});
        LaunchFactory f = _deployFactoryWith(minFees);
        (uint256 i, uint256 b, uint256 inc, uint256 r,, uint256 t) = f.currentFeeBps();
        assertEq(i, 10, "issuer at min");
        assertEq(b, 10, "boardwalk at min");
        assertEq(inc, 0, "incentive at min");
        assertEq(r, 0, "referrer at min");
        assertEq(t, 20, "total at min boundaries");
    }

    function test_Constructor_FeeDefaults_AtMaxBoundaries() public {
        // All components at their maximum valid values; uses _deployFactoryWith (INTEGRATOR_BPS=0).
        LaunchFactory.FeeBpsDefaults memory maxFees =
            LaunchFactory.FeeBpsDefaults({issuer: 80, boardwalk: 50, incentive: 50, referrer: 10, total: 180});
        LaunchFactory f = _deployFactoryWith(maxFees);
        (uint256 i, uint256 b, uint256 inc, uint256 r,, uint256 t) = f.currentFeeBps();
        assertEq(i, 80, "issuer at max");
        assertEq(b, 50, "boardwalk at max");
        assertEq(inc, 50, "incentive at max");
        assertEq(r, 10, "referrer at max");
        assertEq(t, 180, "total at max boundaries");
    }

    function test_Constructor_FeeDefaults_ReferrerEqualsBoardwalk() public {
        // Edge case: referrer == boardwalk (should pass since referrer <= boardwalk)
        LaunchFactory.FeeBpsDefaults memory edge =
            LaunchFactory.FeeBpsDefaults({issuer: 10, boardwalk: 10, incentive: 0, referrer: 10, total: 20});
        LaunchFactory f = _deployFactoryWith(edge);
        (,,, uint256 r,,) = f.currentFeeBps();
        assertEq(r, 10, "referrer == boardwalk should be valid");
    }

    // ================================================================
    //  PHASE 2 — Fix 1: Per-Component Fee Bounds (Timelock Path)
    // ================================================================

    function test_RevertWhen_ExecuteSetFeeDefaults_IssuerBelowMin() public {
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 9, boardwalk: 30, incentive: 20, referrer: 5, total: 59});
        _timelockSetFeeDefaults(bad);
        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        factory.executeSetFeeDefaults(bad);
    }

    function test_RevertWhen_ExecuteSetFeeDefaults_BoardwalkAboveMax() public {
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 30, boardwalk: 51, incentive: 20, referrer: 5, total: 101});
        _timelockSetFeeDefaults(bad);
        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        factory.executeSetFeeDefaults(bad);
    }

    function test_RevertWhen_ExecuteSetFeeDefaults_IncentiveAboveMax() public {
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 30, boardwalk: 30, incentive: 51, referrer: 5, total: 111});
        _timelockSetFeeDefaults(bad);
        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        factory.executeSetFeeDefaults(bad);
    }

    function test_RevertWhen_ExecuteSetFeeDefaults_ReferrerAboveMax() public {
        LaunchFactory.FeeBpsDefaults memory bad =
            LaunchFactory.FeeBpsDefaults({issuer: 30, boardwalk: 30, incentive: 20, referrer: 11, total: 80});
        _timelockSetFeeDefaults(bad);
        vm.expectRevert(LaunchFactory.InvalidFeeDefaults.selector);
        factory.executeSetFeeDefaults(bad);
    }

    function test_ExecuteSetFeeDefaults_AtMinBoundaries() public {
        // Main factory has INTEGRATOR_BPS=2, so total = 10 + 10 + 0 + 2 = 22.
        LaunchFactory.FeeBpsDefaults memory minFees =
            LaunchFactory.FeeBpsDefaults({issuer: 10, boardwalk: 10, incentive: 0, referrer: 0, total: 22});
        _timelockSetFeeDefaults(minFees);

        vm.expectEmit(true, false, false, true);
        emit FeeDefaultsChanged(10, 10, 0, 0);

        factory.executeSetFeeDefaults(minFees);

        (uint256 i, uint256 b, uint256 inc, uint256 r,, uint256 t) = factory.currentFeeBps();
        assertEq(i, 10, "issuer at min via timelock");
        assertEq(b, 10, "boardwalk at min via timelock");
        assertEq(inc, 0, "incentive at min via timelock");
        assertEq(r, 0, "referrer at min via timelock");
        assertEq(t, 22, "total at min via timelock (incl. INTEGRATOR_BPS=2)");
    }

    function test_ExecuteSetFeeDefaults_AtMaxBoundaries() public {
        // Main factory has INTEGRATOR_BPS=2, so total = 80 + 50 + 50 + 2 = 182.
        LaunchFactory.FeeBpsDefaults memory maxFees =
            LaunchFactory.FeeBpsDefaults({issuer: 80, boardwalk: 50, incentive: 50, referrer: 10, total: 182});
        _timelockSetFeeDefaults(maxFees);

        vm.expectEmit(true, false, false, true);
        emit FeeDefaultsChanged(80, 50, 50, 10);

        factory.executeSetFeeDefaults(maxFees);

        (uint256 i, uint256 b, uint256 inc, uint256 r,, uint256 t) = factory.currentFeeBps();
        assertEq(i, 80, "issuer at max via timelock");
        assertEq(b, 50, "boardwalk at max via timelock");
        assertEq(inc, 50, "incentive at max via timelock");
        assertEq(r, 10, "referrer at max via timelock");
        assertEq(t, 182, "total at max via timelock (incl. INTEGRATOR_BPS=2)");
    }

    // ================================================================
    //  PHASE 2 — Fix 1: BMX Burn Amount Range
    // ================================================================

    function test_ExecuteSetBmxBurn_AtMaxBound() public {
        uint256 newAmount = 200e18;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(newAmount)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        factory.executeSetBmxBurn(newAmount);

        assertEq(factory.bmxBurnAmount(), newAmount, "200e18 should be accepted (at bound)");
    }

    function test_RevertWhen_ExecuteSetBmxBurn_AboveMaxBound() public {
        uint256 newAmount = 200e18 + 1;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(newAmount)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.BmxBurnOutOfRange.selector, newAmount));
        factory.executeSetBmxBurn(newAmount);
    }

    function test_RevertWhen_ExecuteSetBmxBurn_WayAboveMaxBound() public {
        uint256 newAmount = 1000e18;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(newAmount)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.BmxBurnOutOfRange.selector, newAmount));
        factory.executeSetBmxBurn(newAmount);
    }

    function test_RevertWhen_ExecuteSetBmxBurn_AboveMaxBound_NotBurned() public {
        uint256 newAmount = 201e18;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(newAmount)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.BmxBurnOutOfRange.selector, newAmount));
        factory.executeSetBmxBurn(newAmount);
    }

    // ================================================================
    //  PHASE 2 — Fix 3B: Presale Range Admin (Timelocked)
    // ================================================================

    // --- Full lifecycle ---

    function test_SignalExecuteSetPresaleRange_ValidRange() public {
        uint256 newMin = 1000;
        uint256 newMax = 4000;

        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(newMin, newMax)));

        (bool isPending, uint256 executeTime, uint256 expiresAt) =
            factory.getPendingChange(factory.ACTION_SET_PRESALE_RANGE());
        assertTrue(isPending, "Change should be pending");
        assertEq(executeTime, block.timestamp + TIMELOCK_DELAY, "executeTime mismatch");
        assertEq(expiresAt, executeTime + TIMELOCK_EXPIRY, "expiresAt mismatch");

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectEmit(true, false, false, true);
        emit PresaleRangeChanged(MIN_PRESALE_PERCENT, MAX_PRESALE_PERCENT, newMin, newMax);

        factory.executeSetPresaleRange(newMin, newMax);

        assertEq(factory.minPresalePercent(), newMin, "minPresalePercent should update");
        assertEq(factory.maxPresalePercent(), newMax, "maxPresalePercent should update");
    }

    function test_ExecuteSetPresaleRange_UpdatesStateCorrectly() public {
        // Verify state before
        assertEq(factory.minPresalePercent(), MIN_PRESALE_PERCENT, "initial min");
        assertEq(factory.maxPresalePercent(), MAX_PRESALE_PERCENT, "initial max");

        // Execute change
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1500, 3500)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetPresaleRange(1500, 3500);

        // Verify state after
        assertEq(factory.minPresalePercent(), 1500, "min should be 1500");
        assertEq(factory.maxPresalePercent(), 3500, "max should be 3500");

        // Verify pending change is cleared
        (bool isPending,,) = factory.getPendingChange(factory.ACTION_SET_PRESALE_RANGE());
        assertFalse(isPending, "pending change should be cleared after execute");
    }

    // --- Boundary tests ---

    function test_ExecuteSetPresaleRange_AtFullBounds() public {
        // Minimum possible range: (500, 5000)
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(500, 5000)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetPresaleRange(500, 5000);

        assertEq(factory.minPresalePercent(), 500, "min should be 500");
        assertEq(factory.maxPresalePercent(), 5000, "max should be 5000");
    }

    function test_ExecuteSetPresaleRange_MinEqualsMax() public {
        // Single-value range: (1000, 1000)
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1000, 1000)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetPresaleRange(1000, 1000);

        assertEq(factory.minPresalePercent(), 1000, "min == max should work");
        assertEq(factory.maxPresalePercent(), 1000, "min == max should work");
    }

    function test_RevertWhen_ExecuteSetPresaleRange_MinTooLow() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(499, 5000)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.InvalidPresaleRange.selector, 499, 5000));
        factory.executeSetPresaleRange(499, 5000);
    }

    function test_RevertWhen_ExecuteSetPresaleRange_MaxTooHigh() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(500, 5001)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.InvalidPresaleRange.selector, 500, 5001));
        factory.executeSetPresaleRange(500, 5001);
    }

    function test_RevertWhen_ExecuteSetPresaleRange_MinGreaterThanMax() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1000, 500)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.InvalidPresaleRange.selector, 1000, 500));
        factory.executeSetPresaleRange(1000, 500);
    }

    function test_RevertWhen_ExecuteSetPresaleRange_MinNotDivisibleBy500() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(501, 5000)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.InvalidPresaleRange.selector, 501, 5000));
        factory.executeSetPresaleRange(501, 5000);
    }

    function test_RevertWhen_ExecuteSetPresaleRange_MaxNotDivisibleBy500() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(500, 4999)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.InvalidPresaleRange.selector, 500, 4999));
        factory.executeSetPresaleRange(500, 4999);
    }

    function test_RevertWhen_ExecuteSetPresaleRange_BothNotDivisibleBy500() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(750, 4250)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.InvalidPresaleRange.selector, 750, 4250));
        factory.executeSetPresaleRange(750, 4250);
    }

    function test_RevertWhen_ExecuteSetPresaleRange_MinZero() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(0, 5000)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.InvalidPresaleRange.selector, 0, 5000));
        factory.executeSetPresaleRange(0, 5000);
    }

    // --- Cancel ---

    function test_CancelSetPresaleRange_Success() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1000, 4000)));

        bytes32 action = factory.ACTION_SET_PRESALE_RANGE();
        (bool isPending,,) = factory.getPendingChange(action);
        assertTrue(isPending, "Should be pending after signal");

        vm.expectEmit(true, false, false, false);
        emit ChangeCanceled(action);

        vm.prank(owner);
        factory.cancelAction(action);

        (isPending,,) = factory.getPendingChange(action);
        assertFalse(isPending, "Should not be pending after cancel");

        // Verify state unchanged
        assertEq(factory.minPresalePercent(), MIN_PRESALE_PERCENT, "min should be unchanged");
        assertEq(factory.maxPresalePercent(), MAX_PRESALE_PERCENT, "max should be unchanged");
    }

    function test_RevertWhen_ExecuteSetPresaleRange_AfterCancel() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1000, 4000)));

        bytes32 action = factory.ACTION_SET_PRESALE_RANGE();
        vm.prank(owner);
        factory.cancelAction(action);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        factory.executeSetPresaleRange(1000, 4000);
    }

    // --- Access control ---

    function test_RevertWhen_SignalSetPresaleRange_NotOwner() public {
        vm.prank(issuer);
        vm.expectRevert();
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1000, 4000)));
    }

    function test_RevertWhen_CancelSetPresaleRange_NotOwner() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1000, 4000)));

        bytes32 action = factory.ACTION_SET_PRESALE_RANGE();
        vm.prank(issuer);
        vm.expectRevert();
        factory.cancelAction(action);
    }

    function test_ExecuteSetPresaleRange_AnyoneCanExecute() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1000, 4000)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Non-owner can execute
        vm.prank(issuer);
        factory.executeSetPresaleRange(1000, 4000);

        assertEq(factory.minPresalePercent(), 1000, "Anyone should be able to execute after delay");
        assertEq(factory.maxPresalePercent(), 4000, "Anyone should be able to execute after delay");
    }

    // --- Timelock mechanics ---

    function test_RevertWhen_ExecuteSetPresaleRange_BeforeDelay() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1000, 4000)));

        // Try immediately — too early
        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockTooEarly.selector, block.timestamp + TIMELOCK_DELAY));
        factory.executeSetPresaleRange(1000, 4000);
    }

    function test_RevertWhen_ExecuteSetPresaleRange_AfterExpiry() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1000, 4000)));

        vm.warp(block.timestamp + TIMELOCK_DELAY + TIMELOCK_EXPIRY + 1);

        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockExpired.selector, block.timestamp - 1));
        factory.executeSetPresaleRange(1000, 4000);
    }

    function test_RevertWhen_ExecuteSetPresaleRange_WrongDataHash() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1000, 4000)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(Timelocked.TimelockDataMismatch.selector);
        factory.executeSetPresaleRange(1500, 3500); // Different values than signaled
    }

    function test_RevertWhen_ExecuteSetPresaleRange_NotSignaled() public {
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        factory.executeSetPresaleRange(1000, 4000);
    }

    // --- Consecutive range changes ---

    function test_SetPresaleRange_ConsecutiveChanges() public {
        uint256 t = block.timestamp;

        // First change
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1000, 4000)));
        t += TIMELOCK_DELAY;
        vm.warp(t);
        factory.executeSetPresaleRange(1000, 4000);

        assertEq(factory.minPresalePercent(), 1000, "first change min");
        assertEq(factory.maxPresalePercent(), 4000, "first change max");

        // Second change
        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(1500, 3500)));
        t += TIMELOCK_DELAY;
        vm.warp(t);
        factory.executeSetPresaleRange(1500, 3500);

        assertEq(factory.minPresalePercent(), 1500, "second change min");
        assertEq(factory.maxPresalePercent(), 3500, "second change max");
    }

    // ================================================================
    //  PHASE 2 — Fuzz Tests
    // ================================================================

    function testFuzz_FeeDefaults_ValidConfigs(
        uint256 issuerBps,
        uint256 boardwalkBps,
        uint256 incentiveBps,
        uint256 referrerBps
    ) public {
        issuerBps = bound(issuerBps, 10, 80);
        boardwalkBps = bound(boardwalkBps, 10, 50);
        incentiveBps = bound(incentiveBps, 0, 50);
        referrerBps = bound(referrerBps, 0, 10);

        // Referrer must be <= boardwalk (always true given ranges, but explicit)
        vm.assume(referrerBps <= boardwalkBps);

        uint256 totalBps = issuerBps + boardwalkBps + incentiveBps;
        // Total can't exceed 190 (max possible = 80+50+50 = 180, always true)
        vm.assume(totalBps <= 190);

        LaunchFactory.FeeBpsDefaults memory fees = LaunchFactory.FeeBpsDefaults({
            issuer: issuerBps, boardwalk: boardwalkBps, incentive: incentiveBps, referrer: referrerBps, total: totalBps
        });

        LaunchFactory f = _deployFactoryWith(fees);
        (uint256 i, uint256 b, uint256 inc, uint256 r,, uint256 t) = f.currentFeeBps();
        assertEq(i, issuerBps, "issuer fuzz mismatch");
        assertEq(b, boardwalkBps, "boardwalk fuzz mismatch");
        assertEq(inc, incentiveBps, "incentive fuzz mismatch");
        assertEq(r, referrerBps, "referrer fuzz mismatch");
        assertEq(t, totalBps, "total fuzz mismatch");
    }

    function testFuzz_SetPresaleRange_ValidRanges(
        uint256 newMin,
        uint256 newMax
    ) public {
        newMin = bound(newMin, 1, 10); // 1–10 → multiply by 500 → 500–5000
        newMax = bound(newMax, 1, 10);
        newMin = newMin * 500;
        newMax = newMax * 500;
        vm.assume(newMin <= newMax);

        vm.prank(owner);
        factory.signalAction(ACTION_SET_PRESALE_RANGE, keccak256(abi.encode(newMin, newMax)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetPresaleRange(newMin, newMax);

        assertEq(factory.minPresalePercent(), newMin, "min fuzz mismatch");
        assertEq(factory.maxPresalePercent(), newMax, "max fuzz mismatch");
    }

    function testFuzz_SetBmxBurn_ValidAmounts(
        uint256 amount
    ) public {
        amount = bound(amount, 0, 200e18);

        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(amount)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetBmxBurn(amount);

        assertEq(factory.bmxBurnAmount(), amount, "bmxBurn fuzz mismatch");
    }

    function testFuzz_SetBmxBurn_RejectsAboveMax(
        uint256 amount
    ) public {
        amount = bound(amount, 200e18 + 1, type(uint128).max);

        vm.prank(owner);
        factory.signalAction(ACTION_SET_BMX_BURN, keccak256(abi.encode(amount)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.BmxBurnOutOfRange.selector, amount));
        factory.executeSetBmxBurn(amount);
    }

    // ================================================================
    //  PHASE 3 — Fix 3A: Timelocked Fee Collector Setter
    // ================================================================

    function test_SignalExecuteSetFeeCollector_Success() public {
        address newCollector = makeAddr("newFeeCollector");

        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(newCollector)));

        (bool isPending, uint256 executeTime, uint256 expiresAt) =
            factory.getPendingChange(factory.ACTION_SET_FEE_COLLECTOR());
        assertTrue(isPending, "Change should be pending");
        assertEq(executeTime, block.timestamp + TIMELOCK_DELAY, "executeTime mismatch");
        assertEq(expiresAt, executeTime + TIMELOCK_EXPIRY, "expiresAt mismatch");

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectEmit(true, true, true, true);
        emit FeeCollectorChanged(boardwalkFeeCollector, newCollector);

        factory.executeSetFeeCollector(newCollector);

        assertEq(factory.boardwalkFeeCollector(), newCollector, "boardwalkFeeCollector should be updated");
    }

    function test_CancelSetFeeCollector_Success() public {
        address newCollector = makeAddr("newFeeCollector");

        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(newCollector)));

        bytes32 action = factory.ACTION_SET_FEE_COLLECTOR();
        (bool isPending,,) = factory.getPendingChange(action);
        assertTrue(isPending, "Should be pending after signal");

        vm.expectEmit(true, false, false, false);
        emit ChangeCanceled(action);

        vm.prank(owner);
        factory.cancelAction(action);

        (isPending,,) = factory.getPendingChange(action);
        assertFalse(isPending, "Should not be pending after cancel");

        // Verify state unchanged
        assertEq(factory.boardwalkFeeCollector(), boardwalkFeeCollector, "feeCollector should be unchanged");
    }

    function test_RevertWhen_SignalSetFeeCollector_NotOwner() public {
        vm.prank(issuer);
        vm.expectRevert();
        factory.signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(makeAddr("newFeeCollector"))));
    }

    function test_RevertWhen_ExecuteSetFeeCollector_ZeroAddress() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(address(0))));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        factory.executeSetFeeCollector(address(0));
    }

    function test_RevertWhen_CancelSetFeeCollector_NotOwner() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(makeAddr("newFeeCollector"))));

        bytes32 action = factory.ACTION_SET_FEE_COLLECTOR();
        vm.prank(issuer);
        vm.expectRevert();
        factory.cancelAction(action);
    }

    function test_RevertWhen_ExecuteSetFeeCollector_BeforeDelay() public {
        address newCollector = makeAddr("newFeeCollector");

        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(newCollector)));

        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockTooEarly.selector, block.timestamp + TIMELOCK_DELAY));
        factory.executeSetFeeCollector(newCollector);
    }

    function test_RevertWhen_ExecuteSetFeeCollector_AfterExpiry() public {
        address newCollector = makeAddr("newFeeCollector");

        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(newCollector)));

        vm.warp(block.timestamp + TIMELOCK_DELAY + TIMELOCK_EXPIRY + 1);

        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockExpired.selector, block.timestamp - 1));
        factory.executeSetFeeCollector(newCollector);
    }

    function test_RevertWhen_ExecuteSetFeeCollector_WrongDataHash() public {
        address newCollector = makeAddr("newFeeCollector");
        address wrongCollector = makeAddr("wrongFeeCollector");

        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(newCollector)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(Timelocked.TimelockDataMismatch.selector);
        factory.executeSetFeeCollector(wrongCollector);
    }

    function test_RevertWhen_ExecuteSetFeeCollector_NotSignaled() public {
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        factory.executeSetFeeCollector(makeAddr("newFeeCollector"));
    }

    function test_ExecuteSetFeeCollector_AnyoneCanExecute() public {
        address newCollector = makeAddr("newFeeCollector");

        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(newCollector)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Non-owner can execute
        vm.prank(issuer);
        factory.executeSetFeeCollector(newCollector);

        assertEq(factory.boardwalkFeeCollector(), newCollector, "Anyone should be able to execute after delay");
    }

    function test_RevertWhen_ExecuteSetFeeCollector_AfterCancel() public {
        address newCollector = makeAddr("newFeeCollector");

        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(newCollector)));

        bytes32 action = factory.ACTION_SET_FEE_COLLECTOR();
        vm.prank(owner);
        factory.cancelAction(action);

        vm.warp(block.timestamp + TIMELOCK_DELAY);

        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        factory.executeSetFeeCollector(newCollector);
    }


    // ============ executeSetFeeCollector duplicate-role revert paths ============

    function test_RevertWhen_ExecuteSetFeeCollector_DuplicateLpManager() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(boardwalkLPManager)));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(LaunchFactory.DuplicateRoleAddress.selector);
        factory.executeSetFeeCollector(boardwalkLPManager);
    }

    // ============ Coverage Gap Tests ============

    function test_RevertWhen_Constructor_InvalidAdvancedDuration_TooShort() public {
        vm.expectRevert(LaunchFactory.InvalidDuration.selector);
        new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(integratorCollector),
                integratorBps: 2,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: 1 hours, // Below MIN_ADVANCED_DURATION (2 days)
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: defaultFeeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );
    }

    function test_RevertWhen_Constructor_InvalidAdvancedDuration_TooLong() public {
        vm.expectRevert(LaunchFactory.InvalidDuration.selector);
        new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(integratorCollector),
                integratorBps: 2,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: 30 days, // Above MAX_ADVANCED_DURATION (14 days)
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: defaultFeeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );
    }

    function test_LaunchCount_ReturnsCorrectCount() public {
        assertEq(factory.launchCount(), 0, "Initial launch count should be 0");

        // Create a launch
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);
        vm.prank(issuer);
        factory.createLaunch(_buildExpressConfig());

        assertEq(factory.launchCount(), 1, "Launch count should be 1 after one launch");
    }

    function test_IsLaunchToken_ReturnsTrueForLaunchToken() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);
        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(_buildExpressConfig());

        assertTrue(factory.isLaunchToken(tokenAddr), "Should return true for launch token");
        assertFalse(factory.isLaunchToken(address(bmx)), "Should return false for non-launch token");
    }

    // ============ NFT Membership Discount ============

    function test_MemberLaunch_DiscountedBmxBurn() public {
        MockNFT nft = new MockNFT();
        LaunchFactory memberFactory = new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(integratorCollector),
                integratorBps: 2,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: defaultFeeBps,
                nftCollection: address(nft),
                memberLaunchDiscountBps: 2500
            })
        );

        nft.mint(issuer, 1);

        uint256 expectedBurn = DEFAULT_BMX_BURN - (DEFAULT_BMX_BURN * 2500 / 10000); // 75e18
        bmx.mint(issuer, expectedBurn);
        vm.prank(issuer);
        bmx.approve(address(memberFactory), expectedBurn);

        uint256 balBefore = bmx.balanceOf(issuer);
        vm.prank(issuer);
        memberFactory.createLaunch(_buildExpressConfig());
        assertEq(bmx.balanceOf(issuer), balBefore - expectedBurn, "Member should burn 75% of BMX");
    }

    function test_NonMemberLaunch_FullBmxBurn() public {
        MockNFT nft = new MockNFT();
        LaunchFactory memberFactory = new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(integratorCollector),
                integratorBps: 2,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: defaultFeeBps,
                nftCollection: address(nft),
                memberLaunchDiscountBps: 2500
            })
        );

        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(memberFactory), DEFAULT_BMX_BURN);

        uint256 balBefore = bmx.balanceOf(issuer);
        vm.prank(issuer);
        memberFactory.createLaunch(_buildExpressConfig());
        assertEq(bmx.balanceOf(issuer), balBefore - DEFAULT_BMX_BURN, "Non-member should burn full BMX");
    }

    function test_MemberLaunch_100PercentDiscount() public {
        MockNFT nft = new MockNFT();
        LaunchFactory memberFactory = new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(integratorCollector),
                integratorBps: 2,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: defaultFeeBps,
                nftCollection: address(nft),
                memberLaunchDiscountBps: 10_000
            })
        );

        nft.mint(issuer, 1);

        uint256 balBefore = bmx.balanceOf(issuer);
        vm.prank(issuer);
        memberFactory.createLaunch(_buildExpressConfig());
        assertEq(bmx.balanceOf(issuer), balBefore, "Member with 100% discount should burn zero BMX");
    }

    function test_RevertWhen_Constructor_MemberDiscountAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.MemberDiscountOutOfRange.selector, 10_001));
        new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(integratorCollector),
                integratorBps: 2,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: defaultFeeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 10_001
            })
        );
    }

    function test_TimelockSetNftCollection() public {
        MockNFT nft = new MockNFT();
        bytes32 action = keccak256("SET_NFT_COLLECTION");

        vm.prank(owner);
        factory.signalAction(action, keccak256(abi.encode(address(nft))));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetNftCollection(address(nft));
        assertEq(factory.nftCollection(), address(nft));
    }

    function test_TimelockSetMemberLaunchDiscount() public {
        bytes32 action = keccak256("SET_MEMBER_LAUNCH_DISCOUNT");

        vm.prank(owner);
        factory.signalAction(action, keccak256(abi.encode(uint256(5000))));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        factory.executeSetMemberLaunchDiscount(5000);
        assertEq(factory.memberLaunchDiscountBps(), 5000);
    }

    function test_RevertWhen_MemberLaunchDiscountAboveMax() public {
        bytes32 action = keccak256("SET_MEMBER_LAUNCH_DISCOUNT");

        vm.prank(owner);
        factory.signalAction(action, keccak256(abi.encode(uint256(10_001))));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.MemberDiscountOutOfRange.selector, 10_001));
        factory.executeSetMemberLaunchDiscount(10_001);
    }

    function test_CancelMemberLaunchDiscountAction() public {
        bytes32 action = keccak256("SET_MEMBER_LAUNCH_DISCOUNT");

        vm.prank(owner);
        factory.signalAction(action, keccak256(abi.encode(uint256(5000))));

        vm.prank(owner);
        factory.cancelAction(action);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert();
        factory.executeSetMemberLaunchDiscount(5000);
    }

    function test_RevertingNft_RevertsOnLaunch() public {
        RevertingNFT badNft = new RevertingNFT();
        LaunchFactory memberFactory = new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(integratorCollector),
                integratorBps: 2,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: defaultFeeBps,
                nftCollection: address(badNft),
                memberLaunchDiscountBps: 2500
            })
        );

        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(memberFactory), DEFAULT_BMX_BURN);

        vm.expectRevert();
        vm.prank(issuer);
        memberFactory.createLaunch(_buildExpressConfig());
    }

    function test_ZeroBmxBurn_WithDiscount_NoExternalCall() public {
        MockNFT nft = new MockNFT();
        LaunchFactory zeroFactory = new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(integratorCollector),
                integratorBps: 2,
                bmxBurnAmount: 0,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: defaultFeeBps,
                nftCollection: address(nft),
                memberLaunchDiscountBps: 2500
            })
        );

        nft.mint(issuer, 1);
        uint256 balBefore = bmx.balanceOf(issuer);
        vm.prank(issuer);
        zeroFactory.createLaunch(_buildExpressConfig());
        assertEq(bmx.balanceOf(issuer), balBefore, "Zero burn with discount should transfer nothing");
    }

    // ============ New INTEGRATOR_COLLECTOR tests ============

    /// @notice INTEGRATOR_COLLECTOR immutable is exposed and matches the address passed at construction.
    function test_INTEGRATOR_COLLECTOR_PublicGetter() public view {
        assertEq(factory.INTEGRATOR_COLLECTOR(), address(integratorCollector), "INTEGRATOR_COLLECTOR mismatch");
    }

    /// @notice Constructor reverts when integrator BPS > 0 but integratorCollector is zero.
    function test_RevertWhen_Constructor_IntegratorBpsNonZeroCollectorZero() public {
        // Integrator BPS = 2, total includes it: 40 + 45 + 28 + 2 = 115.
        LaunchFactory.FeeBpsDefaults memory feeBps = LaunchFactory.FeeBpsDefaults({
            issuer: 40,
            boardwalk: 45,
            incentive: 28,
            referrer: 5,
            total: 115
        });
        vm.expectRevert(LaunchFactory.IntegratorCollectorMismatch.selector);
        new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(0),
                integratorBps: 2,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: feeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );
    }

    /// @notice Constructor reverts when integrator BPS == 0 but integratorCollector is non-zero.
    ///         Closes the footgun where a stale/wrong collector immutable would otherwise gain
    ///         tax-exempt status + max-allowance on every future launch despite never being reached.
    function test_RevertWhen_Constructor_IntegratorBpsZeroCollectorNonZero() public {
        // Integrator BPS = 0, total = 40 + 47 + 28 + 0 = 115. Collector wired to a stray address.
        LaunchFactory.FeeBpsDefaults memory feeBps = LaunchFactory.FeeBpsDefaults({
            issuer: 40,
            boardwalk: 47,
            incentive: 28,
            referrer: 5,
            total: 115
        });
        vm.expectRevert(LaunchFactory.IntegratorCollectorMismatch.selector);
        new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: makeAddr("strayCollector"),
                integratorBps: 0,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: feeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );
    }

    /// @notice Constructor succeeds when integrator BPS == 0 and integratorCollector is zero.
    function test_Constructor_IntegratorBpsZeroCollectorZero_Succeeds() public {
        // Integrator BPS = 0, so total = issuer + boardwalk + incentive + 0 = 115.
        LaunchFactory.FeeBpsDefaults memory feeBps = LaunchFactory.FeeBpsDefaults({
            issuer: 40,
            boardwalk: 47,
            incentive: 28,
            referrer: 5,
            total: 115
        });
        LaunchFactory f = new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bmx: address(bmx),
                raiseToken: address(weth),
                boardwalkRouter: boardwalkRouter,
                boardwalkDexFactory: boardwalkDEXFactory,
                boardwalkLpManager: boardwalkLPManager,
                boardwalkFeeCollector: boardwalkFeeCollector,
                integratorCollector: address(0),
                integratorBps: 0,
                bmxBurnAmount: DEFAULT_BMX_BURN,
                graduationExpress: GRADUATION_EXPRESS,
                graduationAdvanced: GRADUATION_ADVANCED,
                expressDuration: EXPRESS_DURATION,
                advancedDuration: ADVANCED_DURATION,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: feeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );
        assertEq(f.INTEGRATOR_COLLECTOR(), address(0), "INTEGRATOR_COLLECTOR should be zero");
        assertEq(f.INTEGRATOR_BPS(), 0, "INTEGRATOR_BPS should be 0");
        (,,,, uint256 integratorBps,) = f.currentFeeBps();
        assertEq(integratorBps, 0, "currentFeeBps integrator slot should be 0");
    }

    /// @notice Pre-refactor concept: `executeSetFeeDefaults` could enable an integrator bucket on a
    ///         chain with no collector. Post-refactor, integrator BPS is an immutable on the factory
    ///         and CANNOT be set via `executeSetFeeDefaults` at all — so the only way to enable it
    ///         is at deployment time. This test confirms that path is closed and that the
    ///         immutable behavior renames the trade-off to a deployment-time check (M-2 from audit).
    function test_ExecuteSetFeeDefaults_CannotEnableIntegratorBucket() public {
        LaunchFactory f = _deployFactoryWithoutIntegrator();

        // The new defaults have no `integrator` field — that's now immutable. Total must equal
        // issuer + boardwalk + incentive + INTEGRATOR_BPS == 0. So total = 40 + 42 + 28 = 110.
        LaunchFactory.FeeBpsDefaults memory newFees = LaunchFactory.FeeBpsDefaults({
            issuer: 40,
            boardwalk: 42,
            incentive: 28,
            referrer: 5,
            total: 110
        });

        vm.prank(owner);
        f.signalAction(ACTION_SET_FEE_DEFAULTS, keccak256(abi.encode(newFees)));
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Update succeeds — it can ONLY tune the four mutable buckets. INTEGRATOR_BPS stays 0.
        f.executeSetFeeDefaults(newFees);
        assertEq(f.INTEGRATOR_BPS(), 0, "INTEGRATOR_BPS is immutable; admin cannot enable the bucket");
    }

    /// @notice A launched token's exempt list includes the integratorCollector when it is non-zero.
    function test_BuildExemptList_IncludesIntegratorCollector_WhenNonZero() public {
        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(factory), DEFAULT_BMX_BURN);

        vm.prank(issuer);
        address tokenAddr = factory.createLaunch(_buildExpressConfig());

        IBoardwalkToken token = IBoardwalkToken(tokenAddr);
        assertTrue(token.isExempt(address(integratorCollector)), "integratorCollector should be exempt");
    }

    /// @notice A launched token's exempt list does NOT include address(0) when collector is zero.
    function test_BuildExemptList_OmitsIntegratorCollector_WhenZero() public {
        LaunchFactory zeroCollectorFactory = _deployFactoryWithoutIntegrator();

        bmx.mint(issuer, DEFAULT_BMX_BURN);
        vm.prank(issuer);
        bmx.approve(address(zeroCollectorFactory), DEFAULT_BMX_BURN);

        vm.prank(issuer);
        address tokenAddr = zeroCollectorFactory.createLaunch(_buildExpressConfig());

        IBoardwalkToken token = IBoardwalkToken(tokenAddr);
        assertFalse(token.isExempt(address(0)), "address(0) must never be in the exempt list");
    }

    /// @notice executeSetFeeCollector reverts when the new collector equals INTEGRATOR_COLLECTOR.
    function test_RevertWhen_ExecuteSetFeeCollector_DuplicateIntegratorCollector() public {
        vm.prank(owner);
        factory.signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(address(integratorCollector))));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert(LaunchFactory.DuplicateRoleAddress.selector);
        factory.executeSetFeeCollector(address(integratorCollector));
    }
}

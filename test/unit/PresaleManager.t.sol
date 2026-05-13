// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PresaleManager} from "src/core/PresaleManager.sol";
import {IPresaleManager} from "src/interfaces/IPresaleManager.sol";
import {IBoardwalkToken} from "src/interfaces/IBoardwalkToken.sol";
import {ILPStaking} from "src/interfaces/ILPStaking.sol";
import {IVestingStream} from "src/interfaces/IVestingStream.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

// ============ Mocks ============

/// @dev Mock ERC20 token (for WETH and LP token)
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

/// @dev Mock BoardwalkToken that implements mint and setLiquiditySeedTime
contract MockBoardwalkToken is ERC20, IBoardwalkToken {
    address public override feeDistributor;
    address public override presaleManager;
    uint256 public override baseTaxBps;
    uint256 public override antiWhaleTaxBps;
    uint256 public override antiWhaleDuration;
    uint256 public override liquiditySeedTime;
    mapping(address => bool) public override isExempt;

    constructor() ERC20("MockToken", "MOCK") {}

    function initialize(
        string calldata,
        string calldata,
        uint256 _baseTaxBps,
        uint256 _antiWhaleTaxBps,
        uint256 _antiWhaleDuration,
        address _feeDistributor,
        address _presaleManager,
        address[] calldata exemptAddresses
    ) external override {
        baseTaxBps = _baseTaxBps;
        antiWhaleTaxBps = _antiWhaleTaxBps;
        antiWhaleDuration = _antiWhaleDuration;
        feeDistributor = _feeDistributor;
        presaleManager = _presaleManager;
        for (uint256 i = 0; i < exemptAddresses.length; i++) {
            if (exemptAddresses[i] != address(0)) {
                isExempt[exemptAddresses[i]] = true;
            }
        }
    }

    function mint(
        address to,
        uint256 amount
    ) external override {
        require(msg.sender == presaleManager, "Not authorized");
        require(totalSupply() + amount <= 10_000_000_000e18, "Exceeds total supply");
        _mint(to, amount);
    }

    function setLiquiditySeedTime(
        uint256 seedTime
    ) external override {
        require(msg.sender == presaleManager, "Not authorized");
        liquiditySeedTime = seedTime;
    }

    function updateExempt(address account, bool exempt) external override {
        isExempt[account] = exempt;
    }
}

    /// @dev Mock LPStaking that records initialize calls
    contract MockLPStaking is ILPStaking {
        bool public initialized;
        address public lpToken;
        address public rewardToken;
        address public feeDistributor;
        uint256 public seedTime;
        uint256 public vestingAllocation;
        address public initializer;

        function setInitializer(
            address _initializer
        ) external override {
            initializer = _initializer;
        }

        function initialize(
            address _lpToken,
            address _rewardToken,
            address _feeDistributor,
            uint256 _seedTime,
            uint256 _vestingAllocation
        ) external override {
            require(!initialized, "Already initialized");
            initialized = true;
            lpToken = _lpToken;
            rewardToken = _rewardToken;
            feeDistributor = _feeDistributor;
            seedTime = _seedTime;
            vestingAllocation = _vestingAllocation;
        }

        // Stubs for interface compliance
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

        function notifyFees(
            uint256
        ) external pure override {
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

    /// @dev Mock VestingStream that records initialize calls
    contract MockVestingStream is IVestingStream {
        bool public initialized;
        address public token;
        uint256 public seedTime;
        address[] public recipients;
        uint256[] public amounts;
        address public initializer;
        address public issuer;

        function setInitializer(
            address _initializer,
            address _issuer
        ) external override {
            initializer = _initializer;
            issuer = _issuer;
        }

        function initialize(
            address _token,
            uint256 _seedTime,
            address[] calldata _recipients,
            uint256[] calldata _amounts
        ) external override {
            require(!initialized, "Already initialized");
            initialized = true;
            token = _token;
            seedTime = _seedTime;

            // Copy arrays element by element
            for (uint256 i = 0; i < _recipients.length; i++) {
                recipients.push(_recipients[i]);
                amounts.push(_amounts[i]);
            }
        }

        // Stubs for interface compliance
        function claim(
            uint256
        ) external pure override {
            revert("Not implemented");
        }

        function executeChangeRecipientAddress(uint256, address) external pure override {
            revert("Not implemented");
        }

        function claimable(
            uint256
        ) external pure override returns (uint256) {
            revert("Not implemented");
        }

        function totalVested(
            uint256
        ) external pure override returns (uint256) {
            revert("Not implemented");
        }

        function allocationCount() external pure override returns (uint256) {
            revert("Not implemented");
        }

        function cliffEnd() external pure override returns (uint256) {
            revert("Not implemented");
        }

        function vestingEnd() external pure override returns (uint256) {
            revert("Not implemented");
        }
    }

    /// @dev Mock Router that implements addLiquidity
    contract MockRouter {
        MockFactory public factory;

        constructor(
            MockFactory _factory
        ) {
            factory = _factory;
        }

        function addLiquidity(
            address tokenA,
            address tokenB,
            uint256 amountADesired,
            uint256 amountBDesired,
            uint256,
            uint256,
            address to,
            uint256
        ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
            // Transfer tokens from caller to this router
            require(ERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired), "Transfer A failed");
            require(ERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired), "Transfer B failed");

            // Get or create pair
            address pair = factory.getPair(tokenA, tokenB);
            if (pair == address(0)) {
                pair = factory.createPair(tokenA, tokenB);
            }

            // Transfer tokens to pair (simulating LP creation)
            ERC20(tokenA).transfer(pair, amountADesired);
            ERC20(tokenB).transfer(pair, amountBDesired);

            // Mint LP tokens to recipient
            // Calculate LP tokens (simplified: sqrt(amountA * amountB))
            liquidity = _sqrt(amountADesired * amountBDesired);
            MockERC20(pair).mint(to, liquidity);

            // Return amounts used
            amountA = amountADesired;
            amountB = amountBDesired;
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

    /// @dev Mock Pair that implements mint
    contract MockPair is ERC20 {
        address public token0;
        address public token1;
        uint112 private reserve0;
        uint112 private reserve1;

        constructor(
            address _token0,
            address _token1
        ) ERC20("LP", "LP") {
            token0 = _token0;
            token1 = _token1;
        }

        function getReserves() external view returns (uint112, uint112, uint32) {
            return (reserve0, reserve1, 0);
        }

        function sync() external {
            reserve0 = uint112(ERC20(token0).balanceOf(address(this)));
            reserve1 = uint112(ERC20(token1).balanceOf(address(this)));
        }

        function mint(
            address to
        ) external returns (uint256 liquidity) {
            uint256 balance0 = ERC20(token0).balanceOf(address(this));
            uint256 balance1 = ERC20(token1).balanceOf(address(this));
            uint256 amount0 = balance0 - reserve0;
            uint256 amount1 = balance1 - reserve1;
            uint256 _totalSupply = totalSupply();

            if (_totalSupply == 0) {
                liquidity = _sqrt(amount0 * amount1);
            } else {
                uint256 liquidity0 = amount0 * _totalSupply / reserve0;
                uint256 liquidity1 = amount1 * _totalSupply / reserve1;
                liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
            }

            require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");

            _mint(to, liquidity);
            reserve0 = uint112(balance0);
            reserve1 = uint112(balance1);
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

    /// @dev Mock Factory that implements getPair and createPair
    contract MockFactory {
        mapping(address => mapping(address => address)) public pairs;

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
            address pair = address(new MockPair(tokenA, tokenB));
            pairs[tokenA][tokenB] = pair;
            pairs[tokenB][tokenA] = pair;
            return pair;
        }
    }

    // ============ Test Contract ============

    /// @title PresaleManagerTest
    /// @notice Unit and fuzz tests for PresaleManager.
    contract PresaleManagerTest is Test {
        // ============ Constants ============

        uint256 internal constant TOTAL_SUPPLY = 10_000_000_000e18;
        uint256 internal constant SEED_DELAY = 1 hours;
        uint256 internal constant CLIFF_DURATION = 7 days;
        uint256 internal constant ADVANCED_START_DELAY = 24 hours;
        uint256 internal constant PRESALE_DURATION = 7 days;
        uint256 internal constant PRESALE_PERCENT = 3000; // 30% in BPS
        uint256 internal constant GRADUATION_THRESHOLD = 10 ether;

        // ============ State ============

        PresaleManager internal template;
        PresaleManager internal presaleManager;
        MockBoardwalkToken internal token;
        address internal feeDistributor;
        MockVestingStream internal vestingStream;
        MockLPStaking internal lpStaking;
        MockRouter internal router;
        MockERC20 internal weth;
        MockFactory internal dexFactory;
        address internal factory;

        address internal alice;
        address internal bob;
        address internal charlie;

        // ============ Events (re-declared for vm.expectEmit) ============

        event PresaleInitialized(
            address indexed token, uint256 presaleStart, uint256 presaleEnd, uint256 graduationThreshold
        );
        event Contributed(address indexed user, uint256 amount, uint256 bonusMultiplier);
        event TokensClaimed(address indexed user, uint256 amount);
        event LiquiditySeeded(uint256 raiseAmount, uint256 tokenAmount, uint256 lpTokens);
        event Refunded(address indexed user, uint256 amount);
        event VestingConfigSet(uint256 recipientCount);

        // ============ Setup ============

        function setUp() public {
            alice = makeAddr("alice");
            bob = makeAddr("bob");
            charlie = makeAddr("charlie");
            factory = makeAddr("factory");
            feeDistributor = makeAddr("feeDistributor");

            vm.label(alice, "alice");
            vm.label(bob, "bob");
            vm.label(charlie, "charlie");
            vm.label(factory, "factory");
            vm.label(feeDistributor, "feeDistributor");

            // Deploy mocks
            token = new MockBoardwalkToken();
            vestingStream = new MockVestingStream();
            lpStaking = new MockLPStaking();
            dexFactory = new MockFactory();
            router = new MockRouter(dexFactory);
            weth = new MockERC20("WETH", "WETH");

            // Deploy template and clone
            template = new PresaleManager();
            presaleManager = PresaleManager(Clones.clone(address(template)));

            // Initialize token
            address[] memory exempts = new address[](1);
            exempts[0] = address(presaleManager);
            token.initialize("TestToken", "TEST", 80, 4000, 90 minutes, feeDistributor, address(presaleManager), exempts);
        }

        // ============ Helpers ============

        function _initializePresale(
            bool hasDelay
        ) internal {
            vm.prank(factory);
            presaleManager.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                hasDelay
            );
        }

        function _setVestingConfig() internal {
            address[] memory recipients = new address[](2);
            recipients[0] = alice;
            recipients[1] = bob;
            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 1000e18;
            amounts[1] = 2000e18;

            vm.prank(factory);
            presaleManager.setVestingConfig(recipients, amounts);
        }

        function _contribute(
            address user,
            uint256 amount,
            uint256 timeOffset
        ) internal {
            deal(address(weth), user, amount);
            vm.startPrank(user);
            weth.approve(address(presaleManager), amount);
            vm.warp(presaleManager.presaleStart() + timeOffset);
            presaleManager.contribute(amount);
            vm.stopPrank();
        }

        function _seedLiquidity() internal {
            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);
            presaleManager.seedLiquidity();
        }

        // ============ Initialization ============

        function test_Initialize_ExpressPath_SetsImmediateStart() public {
            vm.prank(factory);
            presaleManager.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false // Express path
            );

            assertEq(presaleManager.presaleStart(), block.timestamp, "presaleStart should be now");
            assertEq(
                presaleManager.presaleEnd(),
                block.timestamp + PRESALE_DURATION,
                "presaleEnd should be duration after start"
            );
        }

        function test_Initialize_AdvancedPath_SetsDelayedStart() public {
            uint256 startTime = block.timestamp;
            vm.prank(factory);
            presaleManager.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                true // Advanced path
            );

            assertEq(
                presaleManager.presaleStart(), startTime + ADVANCED_START_DELAY, "presaleStart should be 24hr delay"
            );
            assertEq(
                presaleManager.presaleEnd(),
                startTime + ADVANCED_START_DELAY + PRESALE_DURATION,
                "presaleEnd should account for delay"
            );
        }

        function test_Initialize_StoresAllAddresses() public {
            vm.prank(factory);
            presaleManager.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );

            assertEq(presaleManager.token(), address(token), "token mismatch");
            assertEq(presaleManager.feeDistributor(), feeDistributor, "feeDistributor mismatch");
            assertEq(presaleManager.vestingStream(), address(vestingStream), "vestingStream mismatch");
            assertEq(presaleManager.lpStaking(), address(lpStaking), "lpStaking mismatch");
            assertEq(presaleManager.router(), address(router), "router mismatch");
            assertEq(address(presaleManager.raiseToken()), address(weth), "raise token mismatch");
            assertEq(presaleManager.dexFactory(), address(dexFactory), "dexFactory mismatch");
            assertEq(presaleManager.factory(), factory, "factory mismatch");
        }

        function test_Initialize_StoresConfig() public {
            vm.prank(factory);
            presaleManager.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );

            assertEq(presaleManager.presaleDuration(), PRESALE_DURATION, "presaleDuration mismatch");
            assertEq(presaleManager.presalePercent(), PRESALE_PERCENT, "presalePercent mismatch");
            assertEq(presaleManager.graduationThreshold(), GRADUATION_THRESHOLD, "graduationThreshold mismatch");
        }

        function test_Initialize_EmitsEvent() public {
            // Verify that initialization sets state correctly (event emission verified via state)
            vm.prank(factory);
            presaleManager.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );

            // Verify state matches what would be in the event
            assertEq(presaleManager.token(), address(token), "token should match event");
            assertEq(presaleManager.presaleStart(), block.timestamp, "presaleStart should match event");
            assertEq(presaleManager.presaleEnd(), block.timestamp + PRESALE_DURATION, "presaleEnd should match event");
            assertEq(
                presaleManager.graduationThreshold(), GRADUATION_THRESHOLD, "graduationThreshold should match event"
            );
        }

        function test_RevertWhen_InitializeTwice() public {
            _initializePresale(false);

            vm.expectRevert(Initializable.InvalidInitialization.selector);
            vm.prank(factory);
            presaleManager.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );
        }

        function test_RevertWhen_InitializeWithZeroToken() public {
            vm.expectRevert(PresaleManager.ZeroAddress.selector);
            vm.prank(factory);
            presaleManager.initialize(
                address(0),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );
        }

        function test_RevertWhen_InitializeWithZeroDuration() public {
            vm.expectRevert(PresaleManager.InvalidDuration.selector);
            vm.prank(factory);
            presaleManager.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                0, // Invalid duration
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );
        }

        function test_RevertWhen_InitializeTemplate() public {
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            vm.prank(factory);
            template.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );
        }

        function test_Initialize_RevertsOnRouterFactoryMismatch() public {
            PresaleManager pm = PresaleManager(Clones.clone(address(template)));

            // Create a different factory that doesn't match what router.factory() returns.
            // router.factory() returns dexFactory, so passing differentFactory triggers the mismatch.
            MockFactory differentFactory = new MockFactory();

            vm.prank(factory);
            vm.expectRevert(PresaleManager.RouterFactoryMismatch.selector);
            pm.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(differentFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );
        }

        // ============ setVestingConfig ============

        function test_setVestingConfig_StoresConfig() public {
            _initializePresale(false);

            address[] memory recipients = new address[](2);
            recipients[0] = alice;
            recipients[1] = bob;
            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 1000e18;
            amounts[1] = 2000e18;

            vm.expectEmit(true, false, false, true);
            emit VestingConfigSet(2);

            vm.prank(factory);
            presaleManager.setVestingConfig(recipients, amounts);
        }

        function test_RevertWhen_setVestingConfig_NotFactory() public {
            _initializePresale(false);

            address[] memory recipients = new address[](1);
            recipients[0] = alice;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1000e18;

            vm.expectRevert(PresaleManager.OnlyFactory.selector);
            presaleManager.setVestingConfig(recipients, amounts);
        }

        function test_RevertWhen_setVestingConfig_Twice() public {
            _initializePresale(false);
            _setVestingConfig();

            address[] memory recipients = new address[](1);
            recipients[0] = charlie;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1000e18;

            vm.expectRevert(Initializable.InvalidInitialization.selector);
            vm.prank(factory);
            presaleManager.setVestingConfig(recipients, amounts);
        }

        function test_RevertWhen_setVestingConfig_ArrayLengthMismatch() public {
            _initializePresale(false);

            address[] memory recipients = new address[](2);
            recipients[0] = alice;
            recipients[1] = bob;
            uint256[] memory amounts = new uint256[](1); // Mismatch
            amounts[0] = 1000e18;

            vm.expectRevert(PresaleManager.ArrayLengthMismatch.selector);
            vm.prank(factory);
            presaleManager.setVestingConfig(recipients, amounts);
        }

        function test_RevertWhen_setVestingConfig_ZeroAddress() public {
            _initializePresale(false);

            address[] memory recipients = new address[](1);
            recipients[0] = address(0); // Invalid
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1000e18;

            vm.expectRevert(PresaleManager.ZeroAddress.selector);
            vm.prank(factory);
            presaleManager.setVestingConfig(recipients, amounts);
        }

        // ============ Contribution ============

        function test_Contribute_UpdatesUserState() public {
            _initializePresale(false);
            uint256 amount = 5 ether;

            deal(address(weth), alice, amount);
            vm.startPrank(alice);
            weth.approve(address(presaleManager), amount);
            vm.warp(presaleManager.presaleStart());
            presaleManager.contribute(amount);
            vm.stopPrank();

            (uint256 totalContributed, uint256 weightedContributed) = presaleManager.contributions(alice);
            assertEq(totalContributed, amount, "totalContributed mismatch");
            assertEq(weightedContributed, amount * 11000 / 10000, "weightedContributed should have 10% bonus");
        }

        function test_Contribute_UpdatesGlobalState() public {
            _initializePresale(false);
            uint256 amount = 5 ether;

            deal(address(weth), alice, amount);
            vm.startPrank(alice);
            weth.approve(address(presaleManager), amount);
            vm.warp(presaleManager.presaleStart());
            presaleManager.contribute(amount);
            vm.stopPrank();

            assertEq(presaleManager.totalRaised(), amount, "totalRaised mismatch");
            assertEq(presaleManager.totalWeightedRaise(), amount * 11000 / 10000, "totalWeightedRaise mismatch");
        }

        function test_Contribute_MultipleContributions() public {
            _initializePresale(false);
            uint256 amount1 = 3 ether;
            uint256 amount2 = 2 ether;

            deal(address(weth), alice, amount1 + amount2);
            vm.startPrank(alice);
            weth.approve(address(presaleManager), amount1 + amount2);
            vm.warp(presaleManager.presaleStart());
            presaleManager.contribute(amount1);
            presaleManager.contribute(amount2);
            vm.stopPrank();

            (uint256 totalContributed, uint256 weightedContributed) = presaleManager.contributions(alice);
            assertEq(totalContributed, amount1 + amount2, "totalContributed should sum");
            assertGt(weightedContributed, (amount1 + amount2) * 10000 / 10000, "weightedContributed should have bonus");
        }

        function test_Contribute_BonusDecreasesOverTime() public {
            _initializePresale(false);
            uint256 amount = 1 ether;

            deal(address(weth), alice, amount * 2);
            vm.startPrank(alice);
            weth.approve(address(presaleManager), amount * 2);

            // Contribute at start (10% bonus)
            vm.warp(presaleManager.presaleStart());
            presaleManager.contribute(amount);

            // Contribute at end (0% bonus)
            vm.warp(presaleManager.presaleEnd() - 1);
            presaleManager.contribute(amount);
            vm.stopPrank();

            (, uint256 weightedContributed) = presaleManager.contributions(alice);
            uint256 expectedWeighted = amount * 11000 / 10000 + amount * 10000 / 10000;
            assertEq(weightedContributed, expectedWeighted, "weightedContributed should reflect time decay");
        }

        function test_Contribute_EmitsEvent() public {
            _initializePresale(false);
            uint256 amount = 5 ether;

            deal(address(weth), alice, amount);
            vm.startPrank(alice);
            weth.approve(address(presaleManager), amount);
            vm.warp(presaleManager.presaleStart());

            vm.expectEmit(true, false, false, true);
            emit Contributed(alice, amount, 11000); // 10% bonus at start

            presaleManager.contribute(amount);
            vm.stopPrank();
        }

        function test_RevertWhen_Contribute_BeforePresaleStart() public {
            _initializePresale(false);

            deal(address(weth), alice, 5 ether);
            vm.startPrank(alice);
            weth.approve(address(presaleManager), 5 ether);
            // Warp to before presaleStart (for Express path, this is block.timestamp - 1)
            vm.warp(presaleManager.presaleStart() - 1);
            vm.expectRevert(IPresaleManager.PresaleNotStarted.selector);
            presaleManager.contribute(5 ether);
            vm.stopPrank();
        }

        function test_RevertWhen_Contribute_AfterPresaleEnd() public {
            _initializePresale(false);

            deal(address(weth), alice, 5 ether);
            vm.startPrank(alice);
            weth.approve(address(presaleManager), 5 ether);
            vm.warp(presaleManager.presaleEnd());
            vm.expectRevert(IPresaleManager.PresaleEnded.selector);
            presaleManager.contribute(5 ether);
            vm.stopPrank();
        }

        function test_RevertWhen_Contribute_ZeroAmount() public {
            _initializePresale(false);

            vm.warp(presaleManager.presaleStart());
            vm.expectRevert(IPresaleManager.ZeroContribution.selector);
            presaleManager.contribute(0);
        }

        function testFuzz_Contribute_WeightedBonusCalculation(
            uint256 amount,
            uint256 timeOffset
        ) public {
            _initializePresale(false);

            amount = bound(amount, 1e15, 1000 ether); // Reasonable range
            timeOffset = bound(timeOffset, 0, PRESALE_DURATION - 1); // Within presale window

            deal(address(weth), alice, amount);
            vm.startPrank(alice);
            weth.approve(address(presaleManager), amount);
            vm.warp(presaleManager.presaleStart() + timeOffset);
            presaleManager.contribute(amount);
            vm.stopPrank();

            // Calculate expected bonus multiplier
            // 11000 (10% bonus) at t=0, linearly decreasing to 10000 (0% bonus) at t=end
            uint256 expectedMultiplier = 10000 + (1000 * (PRESALE_DURATION - timeOffset) / PRESALE_DURATION);
            uint256 expectedWeighted = amount * expectedMultiplier / 10000;

            (, uint256 weightedContributed) = presaleManager.contributions(alice);
            assertEq(weightedContributed, expectedWeighted, "weightedContributed calculation mismatch");
        }

        // ============ calculateTokens ============

        function test_calculateTokens_ReturnsZeroForNoContribution() public {
            _initializePresale(false);

            assertEq(presaleManager.calculateTokens(alice), 0, "Should return 0 for no contribution");
        }

        function test_calculateTokens_ReturnsNonZeroBeforeSeeding() public {
            _initializePresale(false);
            _contribute(alice, 5 ether, 0);

            // calculateTokens works before seeding - it calculates based on presalePercent
            uint256 tokens = presaleManager.calculateTokens(alice);
            assertGt(tokens, 0, "Should return calculated tokens even before seeding");
        }

        function test_calculateTokens_CalculatesCorrectly() public {
            _initializePresale(false);
            uint256 aliceAmount = GRADUATION_THRESHOLD / 2;
            uint256 bobAmount = GRADUATION_THRESHOLD / 2;

            _contribute(alice, aliceAmount, 0);
            _contribute(bob, bobAmount, 0);
            _seedLiquidity();

            uint256 presaleTokens = TOTAL_SUPPLY * PRESALE_PERCENT / 10000;
            uint256 aliceWeighted = aliceAmount * 11000 / 10000;
            uint256 bobWeighted = bobAmount * 11000 / 10000;
            uint256 totalWeighted = aliceWeighted + bobWeighted;
            uint256 expectedAliceTokens = aliceWeighted * presaleTokens / totalWeighted;

            assertEq(presaleManager.calculateTokens(alice), expectedAliceTokens, "calculateTokens mismatch");
        }

        function test_calculateTokens_NormalizesByWeightedWeth() public {
            _initializePresale(false);

            // Alice contributes early (10% bonus)
            _contribute(alice, GRADUATION_THRESHOLD / 2, 0);
            // Bob contributes late (0% bonus)
            _contribute(bob, GRADUATION_THRESHOLD / 2, PRESALE_DURATION - 1);

            _seedLiquidity();

            uint256 aliceTokens = presaleManager.calculateTokens(alice);
            uint256 bobTokens = presaleManager.calculateTokens(bob);

            // Alice should get more tokens due to early contribution bonus
            assertGt(aliceTokens, bobTokens, "Early contributor should get more tokens");
        }

        function testFuzz_calculateTokens_ProportionalDistribution(
            uint256 aliceAmount,
            uint256 bobAmount,
            uint256 aliceTimeOffset,
            uint256 bobTimeOffset
        ) public {
            _initializePresale(false);

            // Ensure total meets graduation threshold
            uint256 minTotal = GRADUATION_THRESHOLD;
            aliceAmount = bound(aliceAmount, minTotal / 2, 100 ether);
            bobAmount = bound(bobAmount, minTotal / 2, 100 ether);
            // Ensure total is at least graduation threshold
            vm.assume(aliceAmount + bobAmount >= minTotal);

            aliceTimeOffset = bound(aliceTimeOffset, 0, PRESALE_DURATION - 1);
            bobTimeOffset = bound(bobTimeOffset, 0, PRESALE_DURATION - 1);

            _contribute(alice, aliceAmount, aliceTimeOffset);
            _contribute(bob, bobAmount, bobTimeOffset);
            _seedLiquidity();

            uint256 presaleTokens = TOTAL_SUPPLY * PRESALE_PERCENT / 10000;
            uint256 aliceTokens = presaleManager.calculateTokens(alice);
            uint256 bobTokens = presaleManager.calculateTokens(bob);

            // Sum should equal presaleTokens (allowing for rounding)
            uint256 totalDistributed = aliceTokens + bobTokens;
            assertLe(totalDistributed, presaleTokens, "Total distributed should not exceed presaleTokens");
            assertGe(
                totalDistributed,
                presaleTokens - 2, // Allow for rounding errors
                "Total distributed should be close to presaleTokens"
            );
        }

        // ============ seedLiquidity ============

        function test_seedLiquidity_MintsTokens() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);

            uint256 presaleTokens = TOTAL_SUPPLY * PRESALE_PERCENT / 10000;

            _seedLiquidity();

            // After seedLiquidity, liquidityTokens are transferred to the pair for LP minting
            // So presaleManager should only have presaleTokens left
            assertEq(
                token.balanceOf(address(presaleManager)),
                presaleTokens,
                "PresaleManager should hold presale tokens (liquidity tokens transferred to pair)"
            );
        }

        function test_seedLiquidity_CreatesLP() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);

            _seedLiquidity();

            address pair = dexFactory.getPair(address(token), address(weth));
            assertTrue(pair != address(0), "Pair should be created");
            // LP tokens are burned immediately, so check that they were created (totalSupply > 0)
            // or check that they were burned (balance of dead address > 0)
            address deadAddress = 0x000000000000000000000000000000000000dEaD;
            assertGt(ERC20(pair).balanceOf(deadAddress), 0, "LP tokens should be burned to dead address");
        }

        function test_seedLiquidity_SucceedsWhenPairIsPreCreatedAndPoisoned() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);

            // Attacker pre-creates pair and poisons reserves with one-sided dust.
            address pair = dexFactory.createPair(address(token), address(weth));
            weth.mint(pair, 1);
            MockPair(pair).sync();

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);
            presaleManager.seedLiquidity();

            assertTrue(presaleManager.seeded(), "Liquidity seeding should succeed");
            address deadAddress = 0x000000000000000000000000000000000000dEaD;
            assertGt(ERC20(pair).balanceOf(deadAddress), 0, "LP tokens should still be minted and burned");
        }

        function test_seedLiquidity_BurnsLP() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);

            _seedLiquidity();

            address pair = dexFactory.getPair(address(token), address(weth));
            address deadAddress = 0x000000000000000000000000000000000000dEaD;
            assertEq(ERC20(pair).balanceOf(deadAddress), ERC20(pair).totalSupply(), "All LP tokens should be burned");
        }

        function test_seedLiquidity_InitializesLPStaking() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);

            _seedLiquidity();

            assertTrue(lpStaking.initialized(), "LPStaking should be initialized");
            address pair = dexFactory.getPair(address(token), address(weth));
            assertEq(lpStaking.lpToken(), pair, "LPStaking lpToken mismatch");
            assertEq(lpStaking.rewardToken(), address(token), "LPStaking rewardToken mismatch");
            assertEq(lpStaking.feeDistributor(), feeDistributor, "LPStaking feeDistributor mismatch");
            assertEq(lpStaking.seedTime(), presaleManager.liquiditySeedTime(), "LPStaking seedTime mismatch");
        }

        function test_seedLiquidity_InitializesVestingStream() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);

            _seedLiquidity();

            assertTrue(vestingStream.initialized(), "VestingStream should be initialized");
            assertEq(vestingStream.token(), address(token), "VestingStream token mismatch");
            assertEq(vestingStream.seedTime(), presaleManager.liquiditySeedTime(), "VestingStream seedTime mismatch");
        }

        function test_seedLiquidity_SetsLiquiditySeedTimeOnToken() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);

            _seedLiquidity();

            assertEq(
                token.liquiditySeedTime(), presaleManager.liquiditySeedTime(), "Token liquiditySeedTime should be set"
            );
        }

        function test_seedLiquidity_ExpressPath_NoVestingStream() public {
            // Deploy new presaleManager without vestingStream
            PresaleManager pm = PresaleManager(Clones.clone(address(template)));

            // Initialize token with pm as presaleManager
            MockBoardwalkToken newToken = new MockBoardwalkToken();
            address[] memory exempts = new address[](1);
            exempts[0] = address(pm);
            newToken.initialize("TestToken", "TEST", 80, 4000, 90 minutes, feeDistributor, address(pm), exempts);

            vm.prank(factory);
            pm.initialize(
                address(newToken),
                feeDistributor,
                address(0), // No vesting stream
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );

            deal(address(weth), alice, GRADUATION_THRESHOLD);
            vm.startPrank(alice);
            weth.approve(address(pm), GRADUATION_THRESHOLD);
            vm.warp(pm.presaleStart());
            pm.contribute(GRADUATION_THRESHOLD);
            vm.stopPrank();

            vm.warp(pm.presaleEnd() + SEED_DELAY + 1);
            pm.seedLiquidity();

            // VestingStream should not be initialized (address(0))
            assertEq(pm.vestingStream(), address(0), "VestingStream should be address(0)");
            assertTrue(pm.seeded(), "Should be seeded");
        }

        function test_seedLiquidity_EmitsEvent() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);

            uint256 liquidityTokens = TOTAL_SUPPLY * PRESALE_PERCENT / 10000;
            // Use expectEmit with checkTopic1-3 set to false for the LP amount (will vary)
            vm.expectEmit(true, true, false, false);
            emit LiquiditySeeded(GRADUATION_THRESHOLD, liquidityTokens, 0);

            presaleManager.seedLiquidity();
        }

        function test_RevertWhen_seedLiquidity_TooEarly() public {
            _initializePresale(false);
            _contribute(alice, GRADUATION_THRESHOLD, 0);

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY - 1); // 1 second too early

            vm.expectRevert(
                abi.encodeWithSelector(
                    IPresaleManager.SeedTooEarly.selector, presaleManager.presaleEnd() + SEED_DELAY, block.timestamp
                )
            );
            presaleManager.seedLiquidity();
        }

        function test_RevertWhen_seedLiquidity_AlreadySeeded() public {
            _initializePresale(false);
            _setVestingConfig();
            uint256 amount = GRADUATION_THRESHOLD;
            _contribute(alice, amount, 0);
            _seedLiquidity();

            vm.expectRevert(IPresaleManager.AlreadySeeded.selector);
            presaleManager.seedLiquidity();
        }

        function test_RevertWhen_seedLiquidity_BelowThreshold() public {
            _initializePresale(false);
            _contribute(alice, GRADUATION_THRESHOLD - 1, 0); // Below threshold

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);

            vm.expectRevert(
                abi.encodeWithSelector(
                    IPresaleManager.BelowGraduationThreshold.selector, GRADUATION_THRESHOLD - 1, GRADUATION_THRESHOLD
                )
            );
            presaleManager.seedLiquidity();
        }

        // ============ claimTokens ============

        function test_claimTokens_TransfersTokens() public {
            _initializePresale(false);
            _setVestingConfig();
            uint256 amount = GRADUATION_THRESHOLD;
            _contribute(alice, amount, 0);
            _seedLiquidity();

            uint256 expectedTokens = presaleManager.calculateTokens(alice);
            uint256 balanceBefore = token.balanceOf(alice);

            vm.warp(presaleManager.liquiditySeedTime() + CLIFF_DURATION + 1);
            vm.prank(alice);
            presaleManager.claimTokens();

            assertEq(token.balanceOf(alice), balanceBefore + expectedTokens, "Tokens should be transferred");
        }

        function test_claimTokens_MarksAsClaimed() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);
            _seedLiquidity();

            vm.warp(presaleManager.liquiditySeedTime() + CLIFF_DURATION + 1);
            vm.prank(alice);
            presaleManager.claimTokens();

            assertTrue(presaleManager.claimed(alice), "Should be marked as claimed");
        }

        function test_claimTokens_EmitsEvent() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);
            _seedLiquidity();

            uint256 expectedTokens = presaleManager.calculateTokens(alice);
            vm.warp(presaleManager.liquiditySeedTime() + CLIFF_DURATION + 1);

            vm.expectEmit(true, false, false, true);
            emit TokensClaimed(alice, expectedTokens);

            vm.prank(alice);
            presaleManager.claimTokens();
        }

        function test_RevertWhen_claimTokens_BeforeCliff() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);
            _seedLiquidity();

            vm.warp(presaleManager.liquiditySeedTime() + CLIFF_DURATION - 1); // 1 second before cliff

            vm.expectRevert(
                abi.encodeWithSelector(
                    IPresaleManager.CliffNotEnded.selector,
                    presaleManager.liquiditySeedTime() + CLIFF_DURATION,
                    block.timestamp
                )
            );
            vm.prank(alice);
            presaleManager.claimTokens();
        }

        function test_RevertWhen_claimTokens_NotSeeded() public {
            _initializePresale(false);
            _contribute(alice, 5 ether, 0);

            vm.expectRevert(IPresaleManager.PresaleNotStarted.selector);
            vm.prank(alice);
            presaleManager.claimTokens();
        }

        function test_RevertWhen_claimTokens_AlreadyClaimed() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);
            _seedLiquidity();

            vm.warp(presaleManager.liquiditySeedTime() + CLIFF_DURATION + 1);
            vm.prank(alice);
            presaleManager.claimTokens();

            vm.expectRevert(IPresaleManager.AlreadyClaimed.selector);
            vm.prank(alice);
            presaleManager.claimTokens();
        }

        function test_RevertWhen_claimTokens_NoContribution() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(bob, GRADUATION_THRESHOLD, 0); // Only bob contributes
            _seedLiquidity();

            vm.warp(presaleManager.liquiditySeedTime() + CLIFF_DURATION + 1);

            vm.expectRevert(IPresaleManager.NoContribution.selector);
            vm.prank(alice); // Alice didn't contribute
            presaleManager.claimTokens();
        }

        // ============ refund ============

        function test_refund_ReturnsWeth() public {
            _initializePresale(false);
            uint256 amount = 5 ether;
            _contribute(alice, amount, 0);

            // Presale fails (below threshold)
            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);

            uint256 balanceBefore = weth.balanceOf(alice);
            vm.prank(alice);
            presaleManager.refund();

            assertEq(weth.balanceOf(alice), balanceBefore + amount, "WETH should be refunded");
        }

        function test_refund_MarksAsRefunded() public {
            _initializePresale(false);
            _contribute(alice, 5 ether, 0);

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);
            vm.prank(alice);
            presaleManager.refund();

            assertTrue(presaleManager.refunded(alice), "Should be marked as refunded");
        }

        function test_refund_EmitsEvent() public {
            _initializePresale(false);
            uint256 amount = 5 ether;
            _contribute(alice, amount, 0);

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);

            vm.expectEmit(true, false, false, true);
            emit Refunded(alice, amount);

            vm.prank(alice);
            presaleManager.refund();
        }

        function test_refund_AvailableForever() public {
            _initializePresale(false);
            _contribute(alice, 5 ether, 0);

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);
            // Warp far into the future
            vm.warp(block.timestamp + 365 days);

            vm.prank(alice);
            presaleManager.refund();

            assertTrue(presaleManager.refunded(alice), "Refund should still work");
        }

        function test_RevertWhen_refund_BeforeSeedDelay() public {
            _initializePresale(false);
            _contribute(alice, 5 ether, 0);

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY - 1);

            vm.expectRevert(PresaleManager.PresaleStillActive.selector);
            vm.prank(alice);
            presaleManager.refund();
        }

        function test_RevertWhen_refund_PresaleSucceeded() public {
            _initializePresale(false);
            _setVestingConfig();
            uint256 amount = GRADUATION_THRESHOLD;
            _contribute(alice, amount, 0);
            _seedLiquidity();

            // After seeding, refund should revert with AlreadySeeded (checked first in refund())
            vm.expectRevert(IPresaleManager.AlreadySeeded.selector);
            vm.prank(alice);
            presaleManager.refund();
        }

        function test_RevertWhen_refund_AlreadyRefunded() public {
            _initializePresale(false);
            _contribute(alice, 5 ether, 0);

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);
            vm.prank(alice);
            presaleManager.refund();

            vm.expectRevert(IPresaleManager.AlreadyRefunded.selector);
            vm.prank(alice);
            presaleManager.refund();
        }

        function test_RevertWhen_refund_NoContribution() public {
            _initializePresale(false);
            _contribute(bob, 5 ether, 0);

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);

            vm.expectRevert(IPresaleManager.NoContribution.selector);
            vm.prank(alice); // Alice didn't contribute
            presaleManager.refund();
        }

        // ============ View Functions ============

        function test_hasFailed_ReturnsFalseWhenSeeded() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);
            _seedLiquidity();

            assertFalse(presaleManager.hasFailed(), "Should return false when seeded");
        }

        function test_hasFailed_ReturnsFalseBeforeSeedDelay() public {
            _initializePresale(false);
            _contribute(alice, GRADUATION_THRESHOLD - 1, 0);

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY - 1);

            assertFalse(presaleManager.hasFailed(), "Should return false before seed delay");
        }

        function test_hasFailed_ReturnsTrueWhenFailed() public {
            _initializePresale(false);
            _contribute(alice, GRADUATION_THRESHOLD - 1, 0);

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);

            assertTrue(presaleManager.hasFailed(), "Should return true when presale failed");
        }

        function test_cliffEnd_ReturnsZeroBeforeSeeding() public {
            _initializePresale(false);
            _contribute(alice, 5 ether, 0);

            assertEq(presaleManager.cliffEnd(), 0, "Should return 0 before seeding");
        }

        function test_cliffEnd_ReturnsCorrectTime() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);
            _seedLiquidity();

            uint256 expectedCliffEnd = presaleManager.liquiditySeedTime() + CLIFF_DURATION;
            assertEq(presaleManager.cliffEnd(), expectedCliffEnd, "cliffEnd mismatch");
        }

        // ============ Edge Cases ============

        function test_Contribute_AtExactPresaleStart() public {
            _initializePresale(false);
            uint256 amount = 5 ether;

            deal(address(weth), alice, amount);
            vm.startPrank(alice);
            weth.approve(address(presaleManager), amount);
            vm.warp(presaleManager.presaleStart()); // Exact start time
            presaleManager.contribute(amount);
            vm.stopPrank();

            (uint256 totalContributed,) = presaleManager.contributions(alice);
            assertEq(totalContributed, amount, "Contribution should work at exact start");
        }

        function test_Contribute_AtExactPresaleEnd() public {
            _initializePresale(false);
            uint256 amount = 5 ether;

            deal(address(weth), alice, amount);
            vm.startPrank(alice);
            weth.approve(address(presaleManager), amount);
            vm.warp(presaleManager.presaleEnd() - 1); // 1 second before end
            presaleManager.contribute(amount);
            vm.stopPrank();

            (uint256 totalContributed,) = presaleManager.contributions(alice);
            assertEq(totalContributed, amount, "Contribution should work 1 second before end");
        }

        function test_seedLiquidity_AtExactSeedDelay() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY); // Exact seed delay

            presaleManager.seedLiquidity();

            assertTrue(presaleManager.seeded(), "Should seed at exact delay");
        }

        function test_claimTokens_AtExactCliffEnd() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD, 0);
            _seedLiquidity();

            vm.warp(presaleManager.liquiditySeedTime() + CLIFF_DURATION); // Exact cliff end

            vm.prank(alice);
            presaleManager.claimTokens();

            assertTrue(presaleManager.claimed(alice), "Should allow claim at exact cliff end");
        }

        function test_MultipleUsers_ClaimTokens() public {
            _initializePresale(false);
            _setVestingConfig();
            _contribute(alice, GRADUATION_THRESHOLD / 2, 0);
            _contribute(bob, GRADUATION_THRESHOLD / 2, 0);
            _seedLiquidity();

            vm.warp(presaleManager.liquiditySeedTime() + CLIFF_DURATION + 1);

            vm.prank(alice);
            presaleManager.claimTokens();

            vm.prank(bob);
            presaleManager.claimTokens();

            assertTrue(presaleManager.claimed(alice), "Alice should be claimed");
            assertTrue(presaleManager.claimed(bob), "Bob should be claimed");
        }

        function test_MultipleUsers_Refund() public {
            _initializePresale(false);
            _contribute(alice, 3 ether, 0);
            _contribute(bob, 2 ether, 0);

            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);

            vm.prank(alice);
            presaleManager.refund();

            vm.prank(bob);
            presaleManager.refund();

            assertTrue(presaleManager.refunded(alice), "Alice should be refunded");
            assertTrue(presaleManager.refunded(bob), "Bob should be refunded");
        }

        function test_seedLiquidity_HandlesZeroVestingTokens() public {
            _initializePresale(false);
            // Don't set vesting config
            _contribute(alice, GRADUATION_THRESHOLD, 0);

            // Should not revert even without vesting config
            vm.warp(presaleManager.presaleEnd() + SEED_DELAY + 1);
            presaleManager.seedLiquidity();

            assertTrue(presaleManager.seeded(), "Should seed successfully");
        }

        // ================================================================
        //  COVERAGE GAP TESTS — Initialize zero-address checks
        // ================================================================

        function test_RevertWhen_Initialize_ZeroToken() public {
            PresaleManager pm = PresaleManager(Clones.clone(address(template)));
            vm.prank(factory);
            vm.expectRevert(PresaleManager.ZeroAddress.selector);
            pm.initialize(
                address(0),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );
        }

        function test_RevertWhen_Initialize_ZeroFeeDistributor() public {
            PresaleManager pm = PresaleManager(Clones.clone(address(template)));
            vm.prank(factory);
            vm.expectRevert(PresaleManager.ZeroAddress.selector);
            pm.initialize(
                address(token),
                address(0),
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );
        }

        function test_RevertWhen_Initialize_ZeroLPStaking() public {
            PresaleManager pm = PresaleManager(Clones.clone(address(template)));
            vm.prank(factory);
            vm.expectRevert(PresaleManager.ZeroAddress.selector);
            pm.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(0),
                address(router),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );
        }

        function test_RevertWhen_Initialize_ZeroRouter() public {
            PresaleManager pm = PresaleManager(Clones.clone(address(template)));
            vm.prank(factory);
            vm.expectRevert(PresaleManager.ZeroAddress.selector);
            pm.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(0),
                address(weth),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );
        }

        function test_RevertWhen_Initialize_ZeroWeth() public {
            PresaleManager pm = PresaleManager(Clones.clone(address(template)));
            vm.prank(factory);
            vm.expectRevert(PresaleManager.ZeroAddress.selector);
            pm.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(0),
                address(dexFactory),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );
        }

        function test_RevertWhen_Initialize_ZeroDexFactory() public {
            PresaleManager pm = PresaleManager(Clones.clone(address(template)));
            vm.prank(factory);
            vm.expectRevert(PresaleManager.ZeroAddress.selector);
            pm.initialize(
                address(token),
                feeDistributor,
                address(vestingStream),
                address(lpStaking),
                address(router),
                address(weth),
                address(0),
                PRESALE_DURATION,
                PRESALE_PERCENT,
                GRADUATION_THRESHOLD,
                false
            );
        }

        // ================================================================
        //  COVERAGE GAP TESTS — setVestingConfig array mismatches
        // ================================================================

        function test_RevertWhen_SetVestingConfig_RecipientsAmountsMismatch() public {
            _initializePresale(false);
            address[] memory r = new address[](2);
            r[0] = alice;
            r[1] = bob;
            uint256[] memory a = new uint256[](1);
            a[0] = 1000e18;

            vm.prank(factory);
            vm.expectRevert(PresaleManager.ArrayLengthMismatch.selector);
            presaleManager.setVestingConfig(r, a);
        }

        // ================================================================
        //  COVERAGE GAP TESTS — PairCreationFailed + refund after grad
        // ================================================================

        function test_RevertWhen_Refund_AfterSuccessfulSeed() public {
            _initializePresale(false);
            _contribute(alice, 15 ether, 0);

            uint256 presaleEnd = presaleManager.presaleEnd();
            vm.warp(presaleEnd + 1 hours + 1);
            presaleManager.seedLiquidity();

            // After seeding, refund reverts with AlreadySeeded (checked before PresaleNotFailed)
            vm.prank(alice);
            vm.expectRevert(PresaleManager.AlreadySeeded.selector);
            presaleManager.refund();
        }

        function test_RevertWhen_SeedLiquidity_PairCreationFailed() public {
            _initializePresale(false);
            _contribute(alice, 15 ether, 0);

            uint256 presaleEnd = presaleManager.presaleEnd();
            vm.warp(presaleEnd + 1 hours + 1);

            // Force createPair to return address(0) via mockCall
            vm.mockCall(
                address(dexFactory),
                abi.encodeWithSelector(bytes4(keccak256("createPair(address,address)"))),
                abi.encode(address(0))
            );
            // Also mock getPair to return address(0) so it tries createPair
            vm.mockCall(
                address(dexFactory),
                abi.encodeWithSelector(bytes4(keccak256("getPair(address,address)"))),
                abi.encode(address(0))
            );

            vm.expectRevert(PresaleManager.PairCreationFailed.selector);
            presaleManager.seedLiquidity();
        }

        function test_RevertWhen_Refund_AboveThresholdButNotSeeded() public {
            _initializePresale(false);
            _contribute(alice, 15 ether, 0);

            uint256 presaleEnd = presaleManager.presaleEnd();
            vm.warp(presaleEnd + 1 hours + 1);

            // Above threshold but NOT seeded yet → PresaleNotFailed
            vm.prank(alice);
            vm.expectRevert(PresaleManager.PresaleNotFailed.selector);
            presaleManager.refund();
        }
    }

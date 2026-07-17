// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Core contracts
import {BoardwalkToken} from "src/core/BoardwalkToken.sol";
import {FeeDistributor} from "src/core/FeeDistributor.sol";
import {LPStaking} from "src/core/LPStaking.sol";
import {VestingStream} from "src/core/VestingStream.sol";
import {PresaleManager} from "src/core/PresaleManager.sol";
import {LaunchFactory} from "src/core/LaunchFactory.sol";
import {BoardwalkLPManager} from "src/core/BoardwalkLPManager.sol";
import {BoardwalkFeeCollector} from "src/core/BoardwalkFeeCollector.sol";
import {IntegratorFeeCollector} from "src/core/IntegratorFeeCollector.sol";

// Interfaces
import {IFeeDistributor} from "src/interfaces/IFeeDistributor.sol";
import {ILPStaking} from "src/interfaces/ILPStaking.sol";
import {IPresaleManager} from "src/interfaces/IPresaleManager.sol";
import {IBoardwalkToken} from "src/interfaces/IBoardwalkToken.sol";

/// @dev Mock ERC20 with mint/burn for WETH and BWLK
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
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }
}

/// @dev Minimal mock DEX Factory that creates real pairs via UniswapV2Factory interface
///      For integration tests, we use simplified mock DEX contracts to avoid
///      cross-version compilation complexity. The real DEX fork is tested separately.
contract MockDEXFactory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair) {
        require(getPair[tokenA][tokenB] == address(0), "PAIR_EXISTS");
        pair = address(new MockPair(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
        allPairs.push(pair);
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }
}

/// @dev Minimal mock LP pair (ERC20) that can send tokens it holds
contract MockPair is ERC20 {
    address public token0;
    address public token1;

    constructor(
        address _token0,
        address _token1
    ) ERC20("LP Token", "LP") {
        (token0, token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    /// @dev Uniswap-compatible mint used by PresaleManager direct pair seeding.
    function mint(
        address to
    ) external returns (uint256 liquidity) {
        uint256 balance0 = ERC20(token0).balanceOf(address(this));
        uint256 balance1 = ERC20(token1).balanceOf(address(this));
        uint256 currentLiquidity = _sqrt(balance0 * balance1);
        uint256 existingSupply = totalSupply();

        require(currentLiquidity > existingSupply, "INSUFFICIENT_LIQUIDITY_MINTED");
        liquidity = currentLiquidity - existingSupply;
        _mint(to, liquidity);
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        _burn(from, amount);
    }

    /// @dev Send tokens held by this pair to a recipient (called by router during removeLiquidity)
    function sendTokens(
        address token,
        address to,
        uint256 amount
    ) external {
        ERC20(token).transfer(to, amount);
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

/// @dev Minimal mock Router that handles addLiquidity, swapExactTokensForTokens,
///      and swapExactTokensForTokensSupportingFeeOnTransferTokens
contract MockRouter {
    MockDEXFactory public factory;

    constructor(
        address _factory
    ) {
        factory = MockDEXFactory(_factory);
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
        require(block.timestamp <= deadline, "EXPIRED");

        amountA = amountADesired;
        amountB = amountBDesired;

        // Get or create pair
        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = factory.createPair(tokenA, tokenB);
        }

        // Pull tokens from caller to pair
        ERC20(tokenA).transferFrom(msg.sender, pair, amountA);
        ERC20(tokenB).transferFrom(msg.sender, pair, amountB);

        // Mint LP tokens to recipient
        liquidity = _sqrt(amountA * amountB);
        MockPair(pair).mint(to, liquidity);
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
        require(block.timestamp <= deadline, "EXPIRED");

        address pair = factory.getPair(tokenA, tokenB);
        require(pair != address(0), "PAIR_NOT_FOUND");

        uint256 totalSupply = MockPair(pair).totalSupply();
        uint256 balA = ERC20(tokenA).balanceOf(pair);
        uint256 balB = ERC20(tokenB).balanceOf(pair);

        // Burn LP from caller
        MockPair(pair).burn(msg.sender, liquidity);

        // Calculate proportional amounts
        amountA = balA * liquidity / totalSupply;
        amountB = balB * liquidity / totalSupply;

        // Transfer tokens from pair to recipient
        MockPair(pair).sendTokens(tokenA, to, amountA);
        MockPair(pair).sendTokens(tokenB, to, amountB);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "EXPIRED");
        require(path.length == 2, "INVALID_PATH");

        // Pull input token from caller
        ERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);

        // Simple 1:1 swap for testing (fee distributor is exempt, so full amountIn arrives)
        uint256 amountOut = amountIn / 2; // 50% exchange rate for testing
        require(amountOut >= amountOutMin, "SLIPPAGE");

        // Mint output to recipient
        MockERC20(path[1]).mint(to, amountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, "EXPIRED");
        require(path.length == 2, "INVALID_PATH");

        // Pull input token (may be less due to FOT)
        uint256 balBefore = ERC20(path[0]).balanceOf(address(this));
        ERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 received = ERC20(path[0]).balanceOf(address(this)) - balBefore;

        // Simple exchange rate
        uint256 amountOut = received / 2;
        require(amountOut >= amountOutMin, "SLIPPAGE");

        MockERC20(path[1]).mint(to, amountOut);
    }

    function _sqrt(
        uint256 y
    ) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

/// @title IntegrationBase
/// @notice Shared base for all integration tests. Deploys the full Boardwalk system.
abstract contract IntegrationBase is Test {
    // ============ System Contracts ============

    MockERC20 internal weth;
    MockERC20 internal bwlk;
    MockDEXFactory internal dexFactory;
    MockRouter internal router;

    // Singletons
    LaunchFactory internal factory;
    BoardwalkLPManager internal lpManager;
    BoardwalkFeeCollector internal feeCollector;
    IntegratorFeeCollector internal integratorCollector;

    // Single integrator slot for tests; receives 100% of the integrator bucket.
    address internal integrator;

    // Templates (for cloning)
    BoardwalkToken internal tokenTemplate;
    FeeDistributor internal feeDistributorTemplate;
    PresaleManager internal presaleTemplate;
    LPStaking internal lpStakingTemplate;
    VestingStream internal vestingTemplate;

    // ============ Actors ============

    address internal owner;
    address internal issuer;
    address internal referrer;
    address internal treasury;
    address internal keeper;
    address internal feeRecipient1;
    address internal feeRecipient2;
    address internal vestingRecipient1;
    address internal vestingRecipient2;

    address internal alice;
    address internal bob;
    address internal charlie;

    // ============ Constants ============

    uint256 internal constant DEFAULT_BWLK_BURN = 100e18;
    uint256 internal constant GRADUATION_THRESHOLD = 10 ether;
    uint256 internal constant TOTAL_SUPPLY = 10_000_000_000e18; // 10B tokens
    uint256 internal constant SEED_DELAY = 1 hours;
    uint256 internal constant CLIFF_DURATION = 7 days;

    LaunchFactory.FeeBpsDefaults internal defaultFeeBps;

    // ============ Setup ============

    function setUp() public virtual {
        // Create actors
        owner = makeAddr("owner");
        issuer = makeAddr("issuer");
        referrer = makeAddr("referrer");
        treasury = makeAddr("treasury");
        keeper = makeAddr("keeper");
        feeRecipient1 = makeAddr("feeRecipient1");
        feeRecipient2 = makeAddr("feeRecipient2");
        vestingRecipient1 = makeAddr("vestingRecipient1");
        vestingRecipient2 = makeAddr("vestingRecipient2");
        integrator = makeAddr("integrator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Deploy mock tokens
        weth = new MockERC20("Wrapped Ether", "WETH");
        bwlk = new MockERC20("BWLK", "BWLK");

        // Deploy mock DEX
        dexFactory = new MockDEXFactory();
        router = new MockRouter(address(dexFactory));

        // Deploy templates
        tokenTemplate = new BoardwalkToken();
        feeDistributorTemplate = new FeeDistributor();
        presaleTemplate = new PresaleManager();
        lpStakingTemplate = new LPStaking();
        vestingTemplate = new VestingStream();

        // Deploy singletons
        feeCollector = new BoardwalkFeeCollector(owner, address(weth), address(router), treasury, keeper);

        // Fee defaults: referrer is carve-out from boardwalk. Integrator BPS is now an immutable
        // on the factory (passed via DeployParams.integratorBps) — it does NOT live in this struct.
        // total = issuer + boardwalk + incentive + INTEGRATOR_BPS (referrer excluded).
        defaultFeeBps = LaunchFactory.FeeBpsDefaults({
            issuer: 40, // 0.40%
            boardwalk: 45, // 0.45%
            incentive: 28, // 0.28%
            referrer: 5, // 0.05% (carved from boardwalk)
            total: 115 // 1.15% = 40+45+28+ 2 (integrator immutable)
        });

        // Deploy factory (needs LPManager address, deploy placeholder first)
        lpManager = new BoardwalkLPManager(address(dexFactory), address(router), address(weth));

        // Deploy IntegratorFeeCollector with single test integrator (100% to `integrator`).
        // Owner is `owner`; deployer (this test contract) calls setFactory below since the test
        // contract is the deployer. We transferOwnership to `owner` afterwards if needed by tests.
        address[] memory integratorAddresses = new address[](1);
        integratorAddresses[0] = integrator;
        uint256[] memory integratorSplits = new uint256[](1);
        integratorSplits[0] = 10_000;
        integratorCollector = new IntegratorFeeCollector(
            address(this), address(weth), address(router), integratorAddresses, integratorSplits
        );

        factory = new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenTemplate),
                feeDistributorImpl: address(feeDistributorTemplate),
                presaleImpl: address(presaleTemplate),
                vestingImpl: address(vestingTemplate),
                lpStakingImpl: address(lpStakingTemplate),
                bwlk: address(bwlk),
                raiseToken: address(weth),
                boardwalkRouter: address(router),
                boardwalkDexFactory: address(dexFactory),
                boardwalkLpManager: address(lpManager),
                boardwalkFeeCollector: address(feeCollector),
                integratorCollector: address(integratorCollector),
                integratorBps: 2,
                bwlkBurnAmount: DEFAULT_BWLK_BURN,
                graduationExpress: GRADUATION_THRESHOLD,
                graduationAdvanced: GRADUATION_THRESHOLD,
                expressDuration: 24 hours,
                advancedDuration: 7 days,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: defaultFeeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );

        // One-shot factory wiring on the integrator collector.
        integratorCollector.setFactory(address(factory));
    }

    // ============ Helpers ============

    /// @dev Create an Express launch with default config
    function _createExpressLaunch() internal returns (address tokenAddr) {
        // Mint BWLK for burn
        bwlk.mint(issuer, DEFAULT_BWLK_BURN);
        vm.prank(issuer);
        bwlk.approve(address(factory), DEFAULT_BWLK_BURN);

        // Build config
        address[] memory feeRecipients = new address[](1);
        feeRecipients[0] = feeRecipient1;
        uint256[] memory feeSplits = new uint256[](1);
        feeSplits[0] = 10000;

        string[] memory feeLabels = new string[](1);
        feeLabels[0] = "issuer";

        LaunchFactory.LaunchConfig memory config = LaunchFactory.LaunchConfig({
            name: "Test Token",
            ticker: "TEST",
            category: "DeFi",
            description: "Integration test token",
            path: LaunchFactory.LaunchPath.EXPRESS,
            presalePercent: 5000,
            vestingRecipients: new address[](0),
            vestingPercents: new uint256[](0),
            vestingLabels: new string[](0),
            referrer: address(0),
            issuerFeeRecipients: feeRecipients,
            issuerFeeSplits: feeSplits,
            issuerFeeLabels: feeLabels
        });

        vm.prank(issuer);
        tokenAddr = factory.createLaunch(config);
    }

    /// @dev Create an Advanced launch with vesting and referrer
    function _createAdvancedLaunch() internal returns (address tokenAddr) {
        bwlk.mint(issuer, DEFAULT_BWLK_BURN);
        vm.prank(issuer);
        bwlk.approve(address(factory), DEFAULT_BWLK_BURN);

        address[] memory feeRecipients = new address[](2);
        feeRecipients[0] = feeRecipient1;
        feeRecipients[1] = feeRecipient2;
        uint256[] memory feeSplits = new uint256[](2);
        feeSplits[0] = 6000;
        feeSplits[1] = 4000;

        address[] memory vestRecipients = new address[](2);
        vestRecipients[0] = vestingRecipient1;
        vestRecipients[1] = vestingRecipient2;
        uint256[] memory vestPercents = new uint256[](2);
        vestPercents[0] = 7000;
        vestPercents[1] = 3000;

        string[] memory feeLabels = new string[](2);
        feeLabels[0] = "feeA";
        feeLabels[1] = "feeB";
        string[] memory vestLabels = new string[](2);
        vestLabels[0] = "vestA";
        vestLabels[1] = "vestB";

        LaunchFactory.LaunchConfig memory config = LaunchFactory.LaunchConfig({
            name: "Advanced Token",
            ticker: "ADV",
            category: "DeFi",
            description: "Advanced integration test",
            path: LaunchFactory.LaunchPath.ADVANCED,
            presalePercent: 3000, // 30%
            vestingRecipients: vestRecipients,
            vestingPercents: vestPercents,
            vestingLabels: vestLabels,
            referrer: referrer,
            issuerFeeRecipients: feeRecipients,
            issuerFeeSplits: feeSplits,
            issuerFeeLabels: feeLabels
        });

        vm.prank(issuer);
        tokenAddr = factory.createLaunch(config);
    }

    /// @dev Get LaunchInfo from factory
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

    /// @dev Contribute WETH to a presale
    function _contribute(
        address presale,
        address user,
        uint256 amount
    ) internal {
        weth.mint(user, amount);
        vm.startPrank(user);
        weth.approve(presale, amount);
        IPresaleManager(presale).contribute(amount);
        vm.stopPrank();
    }

    /// @dev Warp to after presale + seed delay, then seed liquidity
    function _seedLiquidity(
        address presale,
        uint256 presaleEnd
    ) internal {
        vm.warp(presaleEnd + SEED_DELAY);
        IPresaleManager(presale).seedLiquidity();
    }
}

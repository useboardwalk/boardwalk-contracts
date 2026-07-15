// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ILiquidityLauncher} from "src/interfaces/ILiquidityLauncher.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ICcaAuctionFactory} from "src/interfaces/ICcaAuctionFactory.sol";

/// @notice Permit2 AllowanceTransfer stand-in: owner-set allowances with expiration, decremented on
///         `transferFrom`, backed by a plain ERC20 approval from the owner to this contract.
contract MockPermit2 {
    using SafeERC20 for IERC20;

    error AllowanceExpired(uint48 expiration);
    error InsufficientAllowance(uint160 allowed, uint256 requested);

    struct PackedAllowance {
        uint160 amount;
        uint48 expiration;
    }

    // owner => token => spender
    mapping(address => mapping(address => mapping(address => PackedAllowance))) public allowance;

    address public lastApproveToken;
    address public lastApproveSpender;
    uint160 public lastApproveAmount;
    uint48 public lastApproveExpiration;

    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external {
        allowance[msg.sender][token][spender] = PackedAllowance(amount, expiration);
        lastApproveToken = token;
        lastApproveSpender = spender;
        lastApproveAmount = amount;
        lastApproveExpiration = expiration;
    }

    function transferFrom(
        address from,
        address to,
        uint160 amount,
        address token
    ) external {
        PackedAllowance storage allowed = allowance[from][token][msg.sender];
        if (block.timestamp > allowed.expiration) revert AllowanceExpired(allowed.expiration);
        if (allowed.amount < amount) revert InsufficientAllowance(allowed.amount, amount);
        if (allowed.amount != type(uint160).max) allowed.amount -= amount;
        IERC20(token).safeTransferFrom(from, to, amount);
    }
}

/// @notice LiquidityLauncher stand-in: same multicall/deposit/distribute semantics as upstream
///         (Permit2 pull from msg.sender, exact-allowance handoff to the strategy), recording every
///         argument so tests can decode the configData back.
contract MockLiquidityLauncher {
    using SafeERC20 for IERC20;

    error AllowanceNotFullyConsumed();

    address public immutable permit2;

    /// @dev True only while multicall() runs; the legs snapshot it so tests can assert the
    ///      deposit+distribute pair actually went through ONE atomic multicall.
    bool public inMulticall;
    bool public depositViaMulticall;
    bool public distributeViaMulticall;

    address public lastDepositToken;
    uint160 public lastDepositAmount;
    address public lastDepositCaller;

    address public lastDistributeToken;
    address public lastStrategy;
    uint128 public lastAmount;
    bytes public lastConfigData;
    bytes32 public lastSalt;
    address public lastDistributeCaller;

    constructor(
        address _permit2
    ) {
        permit2 = _permit2;
    }

    /// @dev Upstream's self-delegatecall batcher; msg.sender is preserved into each leg.
    function multicall(
        bytes[] calldata data
    ) external returns (bytes[] memory results) {
        inMulticall = true;
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            if (!success) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
            results[i] = result;
        }
        inMulticall = false;
    }

    function depositToken(
        address token,
        uint160 amount
    ) external {
        depositViaMulticall = inMulticall;
        lastDepositToken = token;
        lastDepositAmount = amount;
        lastDepositCaller = msg.sender;
        MockPermit2(permit2).transferFrom(msg.sender, address(this), amount, token);
    }

    function distributeToken(
        address token,
        ILiquidityLauncher.Distribution calldata distribution,
        bytes32 salt
    ) external {
        distributeViaMulticall = inMulticall;
        lastDistributeToken = token;
        lastStrategy = distribution.strategy;
        lastAmount = distribution.amount;
        lastConfigData = distribution.configData;
        lastSalt = salt;
        lastDistributeCaller = msg.sender;

        IERC20(token).forceApprove(distribution.strategy, distribution.amount);
        MockLBPStrategy(distribution.strategy)
            .initializeDistribution(
                token, distribution.amount, distribution.configData, keccak256(abi.encode(msg.sender, salt))
            );
        if (IERC20(token).allowance(address(this), distribution.strategy) != 0) revert AllowanceNotFullyConsumed();
    }
}

/// @notice LBPStrategy stand-in: decodes the configData, validates the initializer wiring the way
///         upstream does (fundsRecipient == strategy, tokensRecipient != strategy, endBlock <
///         migrationBlock), creates the auction through the factory with upstream's salt chain, and
///         pulls the auction/reserve split.
contract MockLBPStrategy {
    using SafeERC20 for IERC20;

    error InvalidReservedTokenAmountForLP();
    error InvalidFundsRecipient(address actual, address expected);
    error InvalidTokensRecipient(address actual);
    error InvalidEndBlock(uint256 endBlock, uint256 migrationBlock);

    address public immutable initializerFactory;
    address public immutable positionManager;
    address public immutable poolManager;

    mapping(address => ILBPStrategy.MigratorParameters) internal _initializers;

    constructor(
        address _initializerFactory,
        address _positionManager,
        address _poolManager
    ) {
        initializerFactory = _initializerFactory;
        positionManager = _positionManager;
        poolManager = _poolManager;
    }

    function initializers(
        address initializer
    ) external view returns (ILBPStrategy.MigratorParameters memory) {
        return _initializers[initializer];
    }

    function initializeDistribution(
        address token,
        uint256 totalSupply,
        bytes calldata configData,
        bytes32 salt
    ) external {
        (ILBPStrategy.MigratorParameters memory migrationParams, bytes memory initializerParams) =
            abi.decode(configData, (ILBPStrategy.MigratorParameters, bytes));

        if (migrationParams.reservedTokenAmountForLP >= totalSupply) revert InvalidReservedTokenAmountForLP();
        uint256 auctionSupply = totalSupply - migrationParams.reservedTokenAmountForLP;

        bytes32 initializerSalt = keccak256(abi.encode(salt, migrationParams));
        address auction =
            MockLaunchCcaFactory(initializerFactory).create(token, auctionSupply, initializerParams, initializerSalt);

        address fundsRecipient = MockLaunchCcaAuction(auction).fundsRecipient();
        if (fundsRecipient != address(this)) revert InvalidFundsRecipient(fundsRecipient, address(this));
        address tokensRecipient = MockLaunchCcaAuction(auction).tokensRecipient();
        if (tokensRecipient == address(this)) revert InvalidTokensRecipient(tokensRecipient);
        uint64 endBlock = MockLaunchCcaAuction(auction).endBlock();
        if (endBlock >= migrationParams.migrationBlock) {
            revert InvalidEndBlock(endBlock, migrationParams.migrationBlock);
        }

        _initializers[auction] = migrationParams;

        IERC20(token).safeTransferFrom(msg.sender, auction, auctionSupply);
        IERC20(token).safeTransferFrom(msg.sender, address(this), migrationParams.reservedTokenAmountForLP);
    }
}

/// @notice CCA factory stand-in with upstream's CREATE2 address derivation, so the script's
///         `predictAuction` is exercised end-to-end against a real deployment.
contract MockLaunchCcaFactory {
    function create(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt
    ) external returns (address auction) {
        ICcaAuctionFactory.AuctionParameters memory parameters =
            abi.decode(configData, (ICcaAuctionFactory.AuctionParameters));
        auction = address(
            new MockLaunchCcaAuction{salt: keccak256(abi.encode(msg.sender, salt))}(token, uint128(amount), parameters)
        );
    }

    function getAddress(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt,
        address sender
    ) external view returns (address auction) {
        ICcaAuctionFactory.AuctionParameters memory parameters =
            abi.decode(configData, (ICcaAuctionFactory.AuctionParameters));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(MockLaunchCcaAuction).creationCode, abi.encode(token, uint128(amount), parameters))
        );
        auction = Create2.computeAddress(keccak256(abi.encode(sender, salt)), initCodeHash, address(this));
    }
}

/// @notice ContinuousClearingAuction stand-in: stores the constructor parameters and exposes the
///         getters the script's verification and the tests read.
contract MockLaunchCcaAuction {
    address public token;
    uint128 public totalSupply;
    ICcaAuctionFactory.AuctionParameters internal _parameters;

    constructor(
        address _token,
        uint128 _totalSupply,
        ICcaAuctionFactory.AuctionParameters memory parameters
    ) {
        token = _token;
        totalSupply = _totalSupply;
        _parameters = parameters;
    }

    function auctionParameters() external view returns (ICcaAuctionFactory.AuctionParameters memory) {
        return _parameters;
    }

    function currency() external view returns (address) {
        return _parameters.currency;
    }

    function tokensRecipient() external view returns (address) {
        return _parameters.tokensRecipient;
    }

    function fundsRecipient() external view returns (address) {
        return _parameters.fundsRecipient;
    }

    function startBlock() external view returns (uint64) {
        return _parameters.startBlock;
    }

    function endBlock() external view returns (uint64) {
        return _parameters.endBlock;
    }

    function claimBlock() external view returns (uint64) {
        return _parameters.claimBlock;
    }
}

/// @notice GovernanceVoter stand-in for the launch surface: pool immutables + the one-shot hook flag
///         (false at launch, committed post-migrate).
contract MockLaunchVoter {
    uint24 public POOL_FEE;
    int24 public POOL_TICK_SPACING;
    address public POOL_HOOKS;
    bool public poolHooksSet;

    constructor(
        uint24 fee,
        int24 tickSpacing
    ) {
        POOL_FEE = fee;
        POOL_TICK_SPACING = tickSpacing;
    }

    function setPoolHooks(
        address hooks
    ) external {
        POOL_HOOKS = hooks;
        poolHooksSet = true;
    }
}

/// @notice LPLocker stand-in for the launch-wiring checks.
contract MockLaunchLocker {
    address public GOVERNANCE_VOTER;
    address public CURRENCY0;
    address public CURRENCY1;
    address public registrar;
    address public POSITION_MANAGER;

    constructor(
        address voter,
        address currency0,
        address currency1,
        address _registrar,
        address positionManager
    ) {
        GOVERNANCE_VOTER = voter;
        CURRENCY0 = currency0;
        CURRENCY1 = currency1;
        registrar = _registrar;
        POSITION_MANAGER = positionManager;
    }

    function setRegistrar(
        address _registrar
    ) external {
        registrar = _registrar;
    }
}

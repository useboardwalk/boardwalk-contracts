// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Timelocked} from "../base/Timelocked.sol";
import {IFeeDistributor} from "../interfaces/IFeeDistributor.sol";
import {IDEXRouter} from "../interfaces/IDEXRouter.sol";

/// @title BoardwalkFeeCollector - Protocol fee aggregation and conversion
/// @notice Singleton contract that collects Boardwalk's fee share from all FeeDistributors.
///         Keeper batch-swaps accumulated tokens to the raise token and auto-forwards to treasury.
contract BoardwalkFeeCollector is Ownable2Step, Timelocked {
    using SafeERC20 for IERC20;

    // ============ Immutables ============

    address public immutable RAISE_TOKEN;
    address public immutable ROUTER;

    // ============ Timelock Action Keys ============

    bytes32 public constant ACTION_SET_TREASURY = keccak256("SET_TREASURY");
    bytes32 public constant ACTION_SET_KEEPER = keccak256("SET_KEEPER");
    bytes32 public constant ACTION_MIGRATE_COLLECTOR = keccak256("MIGRATE_COLLECTOR");
    bytes32 public constant ACTION_SET_GOVERNANCE_VAULT = keccak256("SET_GOVERNANCE_VAULT");

    uint256 public constant GOVERNANCE_BPS = 7_000;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // ============ State ============

    address public treasury;
    address public keeper;
    address public governanceVault;

    mapping(address => uint256) public accumulatedFees;

    // ============ Errors ============

    error SwapFailed(address token);
    error NoTokensToSwap();
    error NotKeeper();
    error ArrayLengthMismatch();
    error ZeroAddress();

    // ============ Events ============

    event FeesReceived(address indexed token, uint256 amount);
    event FeesSwapped(address indexed token, uint256 tokenAmount, uint256 raiseTokenAmount);
    event TreasuryUpdated(address indexed newTreasury);
    event KeeperUpdated(address indexed newKeeper);
    event CollectorMigrated(address newCollector, uint256 distributorCount);
    event GovernanceVaultUpdated(address indexed newVault);

    // ============ Constructor ============

    constructor(
        address _owner,
        address _raiseToken,
        address _router,
        address _treasury,
        address _keeper
    ) Ownable(_owner) {
        if (_raiseToken == address(0)) revert ZeroAddress();
        if (_router == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        if (_keeper == address(0)) revert ZeroAddress();

        RAISE_TOKEN = _raiseToken;
        ROUTER = _router;
        treasury = _treasury;
        keeper = _keeper;
    }

    // ============ Fee Collection Logic ============

    /// @notice Called by FeeDistributors to deposit Boardwalk's fee share
    /// @param token The token address being deposited
    /// @param amount Amount of tokens to deposit
    function receiveFees(
        address token,
        uint256 amount
    ) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        accumulatedFees[token] += amount;
        emit FeesReceived(token, amount);
    }

    /// @notice Keeper calls to batch-swap accumulated tokens to raise token and forward to treasury
    /// @param tokens Array of token addresses to swap
    /// @param minAmountsOut Minimum raise token output per token (slippage protection)
    /// @param deadline Transaction deadline timestamp
    function swapToRaiseToken(
        address[] calldata tokens,
        uint256[] calldata minAmountsOut,
        uint256 deadline
    ) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (tokens.length == 0) revert NoTokensToSwap();
        if (tokens.length != minAmountsOut.length) revert ArrayLengthMismatch();

        uint256 totalTokenReceived;

        address[] memory path = new address[](2);
        path[1] = RAISE_TOKEN;

        for (uint256 i = 0; i < tokens.length;) {
            address token = tokens[i];
            uint256 balance = IERC20(token).balanceOf(address(this));

            if (balance == 0) {
                unchecked {
                    ++i;
                }
                continue;
            }

            if (IERC20(token).allowance(address(this), ROUTER) < balance) {
                IERC20(token).forceApprove(ROUTER, type(uint256).max);
            }

            path[0] = token;

            // FeeCollector is exempt from tax
            try IDEXRouter(ROUTER)
                .swapExactTokensForTokens(balance, minAmountsOut[i], path, address(this), deadline) returns (
                uint256[] memory amounts
            ) {
                uint256 tokenReceived = amounts[1];
                totalTokenReceived += tokenReceived;
                accumulatedFees[token] = 0;
                emit FeesSwapped(token, balance, tokenReceived);
            } catch {
                revert SwapFailed(token);
            }
            unchecked {
                ++i;
            }
        }

        if (totalTokenReceived > 0) {
            address _governanceVault = governanceVault;
            if (_governanceVault != address(0)) {
                uint256 governanceAmount = totalTokenReceived * GOVERNANCE_BPS / BPS_DENOMINATOR;
                uint256 treasuryAmount = totalTokenReceived - governanceAmount;
                IERC20(RAISE_TOKEN).safeTransfer(treasury, treasuryAmount);
                IERC20(RAISE_TOKEN).safeTransfer(_governanceVault, governanceAmount);
            } else {
                IERC20(RAISE_TOKEN).safeTransfer(treasury, totalTokenReceived);
            }
        }
    }

    // ============ Timelocked Admin Functions ============

    function _authAdmin(
        bytes32
    ) internal override onlyOwner {}

    /// @notice Execute treasury address change
    function executeSetTreasury(
        address _treasury
    ) external {
        _execute(ACTION_SET_TREASURY, keccak256(abi.encode(_treasury)));
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(_treasury);
        treasury = _treasury;
    }

    /// @notice Execute keeper address change
    function executeSetKeeper(
        address _keeper
    ) external {
        _execute(ACTION_SET_KEEPER, keccak256(abi.encode(_keeper)));
        if (_keeper == address(0)) revert ZeroAddress();
        emit KeeperUpdated(_keeper);
        keeper = _keeper;
    }

    /// @notice Execute governance vault address change
    function executeSetGovernanceVault(
        address _vault
    ) external {
        _execute(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(_vault)));
        emit GovernanceVaultUpdated(_vault);
        governanceVault = _vault;
    }

    /// @notice Execute collector migration. Updates all FeeDistributor clones.
    /// @param _newCollector Must match the signaled newCollector
    /// @param _distributors Must match the signaled distributors array
    function executeMigrateCollector(
        address _newCollector,
        address[] calldata _distributors
    ) external {
        _execute(ACTION_MIGRATE_COLLECTOR, keccak256(abi.encode(_newCollector, _distributors)));
        if (_newCollector == address(0)) revert ZeroAddress();

        for (uint256 i = 0; i < _distributors.length;) {
            IFeeDistributor(_distributors[i]).setFeeCollector(_newCollector);
            unchecked {
                ++i;
            }
        }

        emit CollectorMigrated(_newCollector, _distributors.length);
    }
}

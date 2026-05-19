// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Timelocked} from "../base/Timelocked.sol";
import {IFeeDistributor} from "../interfaces/IFeeDistributor.sol";
import {IDEXRouter} from "../interfaces/IDEXRouter.sol";
import {IGovernanceVoter} from "../interfaces/IGovernanceVoter.sol";

/// @title BoardwalkFeeCollector
/// @notice Singleton aggregator for the boardwalk share of every launch's tax. Keeper batch-swaps
///         to raise token and forwards to treasury. When `governanceVault` is set, raise-token
///         output is split 30% treasury / 70% governanceVault (Base only). Raise-token revenue
///         bridged in from non-Base chains is forwarded by the keeper-only `forwardRevenue`.
contract BoardwalkFeeCollector is Ownable2Step, Timelocked {
    using SafeERC20 for IERC20;

    address public immutable RAISE_TOKEN;
    address public immutable ROUTER;

    bytes32 public constant ACTION_SET_TREASURY = keccak256("SET_TREASURY");
    bytes32 public constant ACTION_SET_KEEPER = keccak256("SET_KEEPER");
    bytes32 public constant ACTION_MIGRATE_COLLECTOR = keccak256("MIGRATE_COLLECTOR");
    bytes32 public constant ACTION_SET_GOVERNANCE_VAULT = keccak256("SET_GOVERNANCE_VAULT");

    uint256 public constant GOVERNANCE_BPS = 7_000;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    address public treasury;
    address public keeper;
    address public governanceVault;

    mapping(address => uint256) public accumulatedFees;

    error SwapFailed(address token);
    error NoTokensToSwap();
    error NotKeeper();
    error ArrayLengthMismatch();
    error ZeroAddress();
    error RaiseTokenMismatch();

    event FeesReceived(address indexed token, uint256 amount);
    event FeesSwapped(address indexed token, uint256 tokenAmount, uint256 raiseTokenAmount);
    event RevenueForwarded(uint256 totalAmount, uint256 governanceAmount, uint256 treasuryAmount);
    event TreasuryUpdated(address indexed newTreasury);
    event KeeperUpdated(address indexed newKeeper);
    event CollectorMigrated(address newCollector, uint256 distributorCount);
    event GovernanceVaultUpdated(address indexed newVault);

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

    /// @notice Called by any FeeDistributor to deposit boardwalk's share of a tax distribution.
    function receiveFees(
        address token,
        uint256 amount
    ) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        accumulatedFees[token] += amount;
        emit FeesReceived(token, amount);
    }

    /// @notice Keeper-only. Batch-swaps accumulated balances to raise token and forwards (split
    ///         treasury/governance if the vault is set).
    function swapToRaiseToken(
        address[] calldata tokens,
        uint256[] calldata minAmountsOut,
        uint256 deadline
    ) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (tokens.length == 0) revert NoTokensToSwap();
        if (tokens.length != minAmountsOut.length) revert ArrayLengthMismatch();

        address[] memory path = new address[](2);
        path[1] = RAISE_TOKEN;

        for (uint256 i = 0; i < tokens.length;) {
            address token = tokens[i];

            if (token == RAISE_TOKEN) {
                unchecked {
                    ++i;
                }
                continue;
            }

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

            // FeeCollector is in every token's exempt list, so the standard swap variant suffices.
            try IDEXRouter(ROUTER)
                .swapExactTokensForTokens(balance, minAmountsOut[i], path, address(this), deadline) returns (
                uint256[] memory amounts
            ) {
                accumulatedFees[token] = 0;
                emit FeesSwapped(token, balance, amounts[1]);
            } catch {
                revert SwapFailed(token);
            }
            unchecked {
                ++i;
            }
        }

        // We use balance here to include potentially bridged revenue added as WETH.
        uint256 toForward = IERC20(RAISE_TOKEN).balanceOf(address(this));
        if (toForward > 0) {
            accumulatedFees[RAISE_TOKEN] = 0;
            _forwardToTreasuryAndGovernance(toForward);
        }
    }

    /// @notice Keeper-only. Forwards the contract's raise-token balance to treasury (and governance
    ///         vault, if set) using the same 30/70 split as `swapToRaiseToken`.
    function forwardRevenue() external {
        if (msg.sender != keeper) revert NotKeeper();
        accumulatedFees[RAISE_TOKEN] = 0;
        uint256 amount = IERC20(RAISE_TOKEN).balanceOf(address(this));
        if (amount == 0) return;
        _forwardToTreasuryAndGovernance(amount);
    }

    function _forwardToTreasuryAndGovernance(
        uint256 amount
    ) internal {
        address _governanceVault = governanceVault;
        uint256 governanceAmount;
        uint256 treasuryAmount;

        if (_governanceVault != address(0)) {
            governanceAmount = amount * GOVERNANCE_BPS / BPS_DENOMINATOR;
            treasuryAmount = amount - governanceAmount;
            IERC20(RAISE_TOKEN).safeTransfer(treasury, treasuryAmount);
            if (IERC20(RAISE_TOKEN).allowance(address(this), _governanceVault) < governanceAmount) {
                IERC20(RAISE_TOKEN).forceApprove(_governanceVault, type(uint256).max);
            }
            IGovernanceVoter(_governanceVault).depositRevenue(governanceAmount);
        } else {
            treasuryAmount = amount;
            IERC20(RAISE_TOKEN).safeTransfer(treasury, treasuryAmount);
        }

        emit RevenueForwarded(amount, governanceAmount, treasuryAmount);
    }

    function _authAdmin(
        bytes32
    ) internal override onlyOwner {}

    function executeSetTreasury(
        address _treasury
    ) external {
        _execute(ACTION_SET_TREASURY, keccak256(abi.encode(_treasury)));
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(_treasury);
        treasury = _treasury;
    }

    function executeSetKeeper(
        address _keeper
    ) external {
        _execute(ACTION_SET_KEEPER, keccak256(abi.encode(_keeper)));
        if (_keeper == address(0)) revert ZeroAddress();
        emit KeeperUpdated(_keeper);
        keeper = _keeper;
    }

    function executeSetGovernanceVault(
        address _vault
    ) external {
        _execute(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(_vault)));
        if (_vault != address(0) && IGovernanceVoter(_vault).WETH() != RAISE_TOKEN) {
            revert RaiseTokenMismatch();
        }
        emit GovernanceVaultUpdated(_vault);
        governanceVault = _vault;
    }

    /// @notice Both `_newCollector` and `_distributors` are committed in the signal hash, so the
    ///         migration cannot be partially applied with a different distributor set.
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

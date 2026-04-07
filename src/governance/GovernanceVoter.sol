// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Timelocked} from "../base/Timelocked.sol";
import {IRewardTracker} from "../interfaces/IRewardTracker.sol";
import {IParticipationDistributor} from "../interfaces/IParticipationDistributor.sol";
import {IUniversalRouter} from "../interfaces/IUniversalRouter.sol";
import {IV4PositionManager} from "../interfaces/IV4PositionManager.sol";
import {ILPLocker} from "../interfaces/ILPLocker.sol";
import {IWETH} from "../interfaces/IWETH.sol";

/// @title GovernanceVoter - Weekly governance voting with protocol revenue execution
/// @notice Merged voter + executor + vault. Receives 70% of protocol revenue from BoardwalkFeeCollector.
///         sbfBMX holders vote weekly on where the governance-directed share goes.
///         Four options: Treasury, Buy&Burn BMX, Buy&Burn LP, Participation Allocation.
///
/// @dev Advance voting model: votes cast in epoch N determine the winner of epoch N+1.
///      finalize(N) snapshots NEW revenue as budget and reads epoch N-1's votes to pick the winner.
///      Epoch 0 always defaults to treasury (no prior votes exist).
///
///      Sequential finalization is strictly enforced: epoch N cannot finalize until epoch N-1
///      is both finalized AND executed. This prevents budget duplication and win streak corruption.
///
///      Per-epoch budget accounting via `accountedBudget` prevents the same WETH balance from
///      being assigned to multiple epochs.
///
///      When the keeper catches up on multiple epochs in one block, each finalize(N) primes
///      epoch N+1 with the current supply. Since supply doesn't change between calls in the
///      same block, the snapshot values are semantically correct.
contract GovernanceVoter is Ownable2Step, Timelocked {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // ============ Constants ============

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant QUORUM_BPS = 5_100;
    uint256 private constant MAX_CONSECUTIVE_WINS = 3;
    uint256 private constant PARTICIPATION_POINTS_GATE_BPS = 150;
    uint256 private constant MAX_GOVERNANCE_BURN = 1e18;
    uint256 private constant GOVERNANCE_TIMELOCK_DELAY = 21 days;
    uint256 public constant FORCE_EXECUTE_DELAY = 14 days;

    address public constant DEAD_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    bytes32 public constant ACTION_SET_GOVERNANCE_BURN = keccak256("SET_GOVERNANCE_BURN");
    bytes32 public constant ACTION_SET_TREASURY = keccak256("SET_TREASURY");
    bytes32 public constant ACTION_SET_FALLBACK_TREASURY = keccak256("SET_FALLBACK_TREASURY");
    bytes32 public constant ACTION_SET_KEEPER = keccak256("SET_KEEPER");

    uint8 public constant OPTION_TREASURY = 1;
    uint8 public constant OPTION_BUY_BURN_BMX = 2;
    uint8 public constant OPTION_BUY_BURN_LP = 3;
    uint8 public constant OPTION_PARTICIPATION = 4;
    uint8 private constant NUM_OPTIONS = 4;

    // Universal Router command IDs
    bytes1 private constant UR_V4_SWAP = 0x10;
    bytes1 private constant UR_V4_POSITION_MANAGER_CALL = 0x14;

    // ============ Immutables ============

    IRewardTracker public immutable SBF_BMX;
    IRewardTracker public immutable STAKED_BMX_TRACKER;
    address public immutable BN_BMX;
    address public immutable BMX;
    address public immutable WETH; // also the raise token
    address public immutable UNIVERSAL_ROUTER;
    address public immutable V4_POSITION_MANAGER;
    uint256 public immutable EPOCH_ZERO;
    uint256 public immutable EPOCH_DURATION;

    // v4 BMX/WETH pool configuration
    uint24 public immutable POOL_FEE;
    int24 public immutable POOL_TICK_SPACING;
    address public immutable POOL_HOOKS;

    // ============ Types ============

    struct EpochInfo {
        uint256 snapshotTotalWeight;
        uint256 budget;
        uint256 totalVoteWeight;
        uint256[4] optionWeights;
        uint64 voterCount;
        uint8 winningOption;
        bool snapshotSet;
        bool finalized;
        bool executed;
    }

    struct UserVote {
        uint248 weight;
        uint8 option;
    }

    // ============ State ============

    address public treasury;
    address public keeper;
    address public fallbackTreasury;

    /// @notice Peer contracts — set once via initializePeers() after deployment
    address public lpLocker;
    address public participationDistributor;
    bool public peersInitialized;

    /// @notice Sum of budgets for finalized-but-not-executed epochs.
    uint256 public accountedBudget;

    uint256 public governanceBurnAmount;
    mapping(uint256 => EpochInfo) public epochInfoStorage;
    mapping(uint256 => mapping(address => UserVote)) public userVotes;
    uint256[4] public consecutiveWinCount;
    uint256[4] public lastIneligibleEpoch;
    uint256 public lastFinalizedEpoch;

    mapping(uint256 => address[]) internal epochVoters;
    mapping(uint256 => uint256) internal validationCursor;
    bool public finalizationInProgress;
    uint256 private finalizingEpoch;

    // ============ Errors ============

    error EpochNotActive();
    error AlreadyVoted();
    error InvalidOption();
    error OptionIneligible(uint8 option);
    error InsufficientVotingWeight();
    error InsufficientParticipationPoints();
    error EpochNotFinalized();
    error EpochAlreadyFinalized();
    error EpochAlreadyExecuted();
    error EpochNotExecutable();
    error PreviousEpochNotExecuted();
    error GovernanceBurnOutOfRange(uint256 amount);
    error NotKeeper();
    error EpochNotOverdue();
    error FinalizationInProgress();
    error WrongFinalizeEpoch();
    error ZeroBatch();
    error ZeroAddress();
    error OnlyWETH();
    error PeersAlreadyInitialized();
    error PeerWiringMismatch();
    error PeersNotInitialized();

    // ============ Events ============

    event Voted(uint256 indexed epoch, address indexed voter, uint8 option, uint256 weight);
    event EpochFinalized(uint256 indexed epoch, uint8 winningOption, bool quorumMet, uint256 budget);
    event EpochExecuted(
        uint256 indexed epoch, uint8 option, uint256 raiseTokenAmount, bool forced, address destination
    );
    event GovernanceBurnChanged(uint256 oldAmount, uint256 newAmount);
    event TreasuryChanged(address oldAddress, address newAddress);
    event KeeperChanged(address oldKeeper, address newKeeper);
    event FallbackTreasuryChanged(address oldAddress, address newAddress);
    event PeersInitialized(address lpLocker, address participationDistributor);

    // ============ Constructor ============

    struct DeployParams {
        address sbfBmx;
        address stakedBmxTracker;
        address bnBmx;
        address bmx;
        address weth;
        address universalRouter;
        address v4PositionManager;
        address treasury;
        address fallbackTreasury;
        uint256 epochZero;
        uint256 epochDuration;
        uint24 poolFee;
        int24 poolTickSpacing;
        address poolHooks;
        address keeper;
    }

    constructor(
        address _owner,
        DeployParams memory p
    ) Ownable(_owner) {
        SBF_BMX = IRewardTracker(p.sbfBmx);
        STAKED_BMX_TRACKER = IRewardTracker(p.stakedBmxTracker);
        BN_BMX = p.bnBmx;
        BMX = p.bmx;
        WETH = p.weth;
        UNIVERSAL_ROUTER = p.universalRouter;
        V4_POSITION_MANAGER = p.v4PositionManager;
        EPOCH_ZERO = p.epochZero;
        EPOCH_DURATION = p.epochDuration;
        POOL_FEE = p.poolFee;
        POOL_TICK_SPACING = p.poolTickSpacing;
        POOL_HOOKS = p.poolHooks;

        if (p.treasury == address(0)) revert ZeroAddress();
        treasury = p.treasury;
        if (p.fallbackTreasury == address(0)) revert ZeroAddress();
        fallbackTreasury = p.fallbackTreasury;
        if (p.keeper == address(0)) revert ZeroAddress();
        keeper = p.keeper;

        // type(uint256).max = "never ineligible"; no real epoch will match
        lastIneligibleEpoch[0] = type(uint256).max;
        lastIneligibleEpoch[1] = type(uint256).max;
        lastIneligibleEpoch[2] = type(uint256).max;
        lastIneligibleEpoch[3] = type(uint256).max;
    }

    /// @dev Accept native ETH from WETH.withdraw() and PositionManager SWEEP.
    receive() external payable {
        if (msg.sender != WETH && msg.sender != V4_POSITION_MANAGER) revert OnlyWETH();
    }

    // ============ Modifiers ============

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        _;
    }

    // ============ Peer Initialization ============

    /// @notice Wire peer contracts after deployment. Can only be called once.
    function initializePeers(
        address _lpLocker,
        address _participationDistributor
    ) external onlyOwner {
        if (peersInitialized) revert PeersAlreadyInitialized();
        if (_lpLocker == address(0) || _participationDistributor == address(0)) revert ZeroAddress();
        if (ILPLocker(_lpLocker).GOVERNANCE_VOTER() != address(this)) revert PeerWiringMismatch();
        if (IParticipationDistributor(_participationDistributor).GOVERNANCE_VOTER() != address(this)) {
            revert PeerWiringMismatch();
        }
        lpLocker = _lpLocker;
        participationDistributor = _participationDistributor;
        peersInitialized = true;
        emit PeersInitialized(_lpLocker, _participationDistributor);
    }

    // ============ Voting ============

    /// @notice Cast a vote for the current epoch. Advance voting: vote in epoch N directs fees for epoch N+1.
    /// @param option Vote option (1=Treasury, 2=BuyBurnBMX, 3=BuyBurnLP, 4=Participation)
    function vote(
        uint8 option
    ) external {
        if (finalizationInProgress) revert FinalizationInProgress();
        if (option < 1 || option > NUM_OPTIONS) revert InvalidOption();

        uint256 epoch = currentEpoch();
        EpochInfo storage e = epochInfoStorage[epoch];

        if (e.finalized) revert EpochNotActive();

        if (!e.snapshotSet) {
            _primeEpoch(epoch);
        }

        UserVote storage uv = userVotes[epoch][msg.sender];
        if (uv.option != 0) revert AlreadyVoted();

        uint256 weight = SBF_BMX.balanceOf(msg.sender);
        if (weight == 0) revert InsufficientVotingWeight();

        uint256 stakedBmx = STAKED_BMX_TRACKER.depositBalances(msg.sender, BMX);
        uint256 stakedMp = SBF_BMX.depositBalances(msg.sender, BN_BMX);
        if (stakedBmx > 0 && stakedMp * BPS_DENOMINATOR < stakedBmx * PARTICIPATION_POINTS_GATE_BPS) {
            revert InsufficientParticipationPoints();
        }

        if (!_isOptionEligible(option, epoch)) revert OptionIneligible(option);

        uint256 burnAmount = governanceBurnAmount;
        if (burnAmount > 0) {
            IERC20(BMX).safeTransferFrom(msg.sender, DEAD_ADDRESS, burnAmount);
        }

        uv.option = option;
        uv.weight = weight.toUint248();
        e.totalVoteWeight += weight;
        e.optionWeights[option - 1] += weight;
        e.voterCount++;
        epochVoters[epoch].push(msg.sender);

        emit Voted(epoch, msg.sender, option, weight);
    }

    // ============ Finalization ============

    /// @notice Finalize an epoch after it ends. Call repeatedly with maxBatch until complete.
    /// @param epoch The epoch to finalize
    /// @param maxBatch Maximum number of voters to re-validate in this call
    function finalize(
        uint256 epoch,
        uint256 maxBatch
    ) external onlyKeeperOrOwner {
        if (maxBatch == 0) revert ZeroBatch();

        EpochInfo storage e = epochInfoStorage[epoch];
        if (e.finalized) revert EpochAlreadyFinalized();
        if (epoch >= currentEpoch()) revert EpochNotExecutable();

        if (!finalizationInProgress) {
            // Strictly sequential: previous epoch must be finalized AND executed
            if (epoch > 0) {
                EpochInfo storage prev = epochInfoStorage[epoch - 1];
                if (!prev.finalized || !prev.executed) revert PreviousEpochNotExecuted();
            }
            finalizationInProgress = true;
            finalizingEpoch = epoch;

            // Per-epoch budget: only new revenue since last finalization
            uint256 currentBalance = IERC20(WETH).balanceOf(address(this));
            e.budget = currentBalance - accountedBudget;
            accountedBudget = currentBalance;
        } else {
            if (finalizingEpoch != epoch) revert WrongFinalizeEpoch();
        }

        // Validate prior epoch's voters (advance voting: epoch N uses epoch N-1's votes)
        if (epoch > 0) {
            _validateVoters(epoch - 1, maxBatch);
            if (validationCursor[epoch - 1] < epochVoters[epoch - 1].length) return;
        }

        finalizationInProgress = false;

        (uint8 winner, bool quorumMet) = _determineWinner(epoch);
        e.winningOption = winner;
        e.finalized = true;

        _primeEpoch(epoch + 1);

        lastFinalizedEpoch = epoch;

        emit EpochFinalized(epoch, winner, quorumMet, e.budget);
    }

    // ============ Execution ============

    /// @notice Execute the winning option for a finalized epoch. Keeper or owner only.
    /// @param epoch The epoch to execute
    /// @param amountOutMin Minimum BMX output for swap-based options (slippage protection)
    /// @param liquidity Liquidity amount for Option 3 (BuyBurnLP) mint. Ignored for other options.
    /// @param deadline Transaction deadline timestamp
    function execute(
        uint256 epoch,
        uint256 amountOutMin,
        uint256 liquidity,
        uint256 deadline
    ) external onlyKeeperOrOwner {
        if (!peersInitialized) revert PeersNotInitialized();
        EpochInfo storage e = epochInfoStorage[epoch];
        if (!e.finalized) revert EpochNotFinalized();
        if (e.executed) revert EpochAlreadyExecuted();

        e.executed = true;
        accountedBudget -= e.budget;

        uint256 amount = e.budget;
        if (amount == 0) {
            emit EpochExecuted(epoch, e.winningOption, 0, false, address(0));
            return;
        }

        uint8 option = e.winningOption;

        if (option == OPTION_TREASURY) {
            address _treasury = treasury;
            IERC20(WETH).safeTransfer(_treasury, amount);
            emit EpochExecuted(epoch, option, amount, false, _treasury);
        } else if (option == OPTION_BUY_BURN_BMX) {
            _executeBuyBurnBmx(amount, amountOutMin, deadline);
            emit EpochExecuted(epoch, option, amount, false, DEAD_ADDRESS);
        } else if (option == OPTION_BUY_BURN_LP) {
            _executeBuyBurnLp(amount, amountOutMin, liquidity, deadline);
            emit EpochExecuted(epoch, option, amount, false, lpLocker);
        } else if (option == OPTION_PARTICIPATION) {
            _executeParticipation(epoch, amount, amountOutMin, deadline);
            emit EpochExecuted(epoch, option, amount, false, epoch == 0 ? treasury : participationDistributor);
        }
    }

    /// @notice Permissionless deadlock resolver. After FORCE_EXECUTE_DELAY past epoch end,
    ///         anyone can mark a stuck epoch as executed and route its budget to the fallback treasury.
    function forceMarkExecuted(
        uint256 epoch
    ) external {
        EpochInfo storage e = epochInfoStorage[epoch];
        if (!e.finalized) revert EpochNotFinalized();
        if (e.executed) revert EpochAlreadyExecuted();

        uint256 epochEnd = EPOCH_ZERO + (epoch + 1) * EPOCH_DURATION;
        if (block.timestamp < epochEnd + FORCE_EXECUTE_DELAY) revert EpochNotOverdue();

        e.executed = true;
        uint256 amount = e.budget;
        accountedBudget -= amount;

        if (amount > 0) {
            address _fallbackTreasury = fallbackTreasury;
            IERC20(WETH).safeTransfer(_fallbackTreasury, amount);
            emit EpochExecuted(epoch, OPTION_TREASURY, amount, true, _fallbackTreasury);
        } else {
            emit EpochExecuted(epoch, OPTION_TREASURY, 0, true, address(0));
        }
    }

    // ============ View Functions ============

    /// @notice Get the current epoch number
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - EPOCH_ZERO) / EPOCH_DURATION;
    }

    /// @notice Get info for an epoch
    function getEpochInfo(
        uint256 epoch
    ) external view returns (EpochInfo memory) {
        return epochInfoStorage[epoch];
    }

    /// @notice Get a user's vote for an epoch
    function getUserVote(
        uint256 epoch,
        address user
    ) external view returns (UserVote memory) {
        return userVotes[epoch][user];
    }

    /// @notice Check if an option is eligible for voting in the current epoch
    function isOptionEligible(
        uint8 option
    ) external view returns (bool) {
        return _isOptionEligible(option, currentEpoch());
    }

    /// @notice Get the list of voter addresses for an epoch
    function getEpochVoters(
        uint256 epoch
    ) external view returns (address[] memory) {
        return epochVoters[epoch];
    }

    // ============ Admin Functions ============

    function _authAdmin(
        bytes32
    ) internal override onlyOwner {}

    /// @dev _burnDelay is intentionally NOT overridden. It delegates to _actionDelay(),
    ///      giving governance actions a 21-day burn delay and standard actions a 7-day burn delay.
    function _actionDelay(
        bytes32 action
    ) internal view override returns (uint256) {
        if (action == ACTION_SET_GOVERNANCE_BURN || action == ACTION_SET_FALLBACK_TREASURY) {
            return GOVERNANCE_TIMELOCK_DELAY;
        }
        return TIMELOCK_DELAY;
    }

    /// @notice Execute governance burn amount change
    function executeSetGovernanceBurn(
        uint256 _amount
    ) external {
        _execute(ACTION_SET_GOVERNANCE_BURN, keccak256(abi.encode(_amount)));
        if (_amount > MAX_GOVERNANCE_BURN) revert GovernanceBurnOutOfRange(_amount);
        emit GovernanceBurnChanged(governanceBurnAmount, _amount);
        governanceBurnAmount = _amount;
    }

    /// @notice Execute treasury address change
    function executeSetTreasury(
        address _treasury
    ) external {
        _executeNonZeroAddress(ACTION_SET_TREASURY, _treasury);
        emit TreasuryChanged(treasury, _treasury);
        treasury = _treasury;
    }

    /// @notice Execute keeper address change
    function executeSetKeeper(
        address _keeper
    ) external {
        _executeNonZeroAddress(ACTION_SET_KEEPER, _keeper);
        emit KeeperChanged(keeper, _keeper);
        keeper = _keeper;
    }

    /// @notice Execute fallback treasury address change
    function executeSetFallbackTreasury(
        address _fallbackTreasury
    ) external {
        _executeNonZeroAddress(ACTION_SET_FALLBACK_TREASURY, _fallbackTreasury);
        emit FallbackTreasuryChanged(fallbackTreasury, _fallbackTreasury);
        fallbackTreasury = _fallbackTreasury;
    }

    // ============ Internal ============

    /// @dev Shared timelock execute + non-zero address validation for admin setters
    function _executeNonZeroAddress(
        bytes32 action,
        address addr
    ) internal {
        _execute(action, keccak256(abi.encode(addr)));
        if (addr == address(0)) revert ZeroAddress();
    }

    /// @dev Determine winning option from prior epoch's votes (advance voting model).
    ///      Epoch 0 defaults to treasury. Handles quorum, eligibility, and consecutive-win tracking.
    function _determineWinner(
        uint256 epoch
    ) internal returns (uint8 winner, bool quorumMet) {
        if (epoch == 0) {
            return (OPTION_TREASURY, false);
        }

        EpochInfo storage votingEpoch = epochInfoStorage[epoch - 1];

        // Quorum: use min(snapshot, liveSupply) to handle supply changes during epoch.
        // If supply increases after priming, quorum is easier to reach against the primed snapshot.
        // This is an accepted design tradeoff -- the min() prevents manipulation via supply deflation.
        uint256 liveSupply = SBF_BMX.totalSupply();
        uint256 quorumBase = votingEpoch.snapshotTotalWeight < liveSupply ? votingEpoch.snapshotTotalWeight : liveSupply;

        quorumMet = quorumBase > 0 && votingEpoch.snapshotSet && votingEpoch.totalVoteWeight > 0
            && votingEpoch.totalVoteWeight * BPS_DENOMINATOR >= quorumBase * QUORUM_BPS;

        if (!quorumMet) {
            for (uint8 i = 0; i < NUM_OPTIONS;) {
                consecutiveWinCount[i] = 0;
                unchecked {
                    ++i;
                }
            }
            return (OPTION_TREASURY, false);
        }

        uint256 highestWeight;
        for (uint8 i = 0; i < NUM_OPTIONS;) {
            if (_isOptionEligible(i + 1, epoch) && votingEpoch.optionWeights[i] > highestWeight) {
                highestWeight = votingEpoch.optionWeights[i];
                winner = i + 1;
            }
            unchecked {
                ++i;
            }
        }

        if (winner > 0) {
            _updateConsecutiveWins(winner, epoch);
        } else {
            winner = OPTION_TREASURY;
        }
    }

    function _primeEpoch(
        uint256 epoch
    ) internal {
        EpochInfo storage e = epochInfoStorage[epoch];
        if (!e.snapshotSet) {
            e.snapshotTotalWeight = SBF_BMX.totalSupply();
            e.snapshotSet = true;
        }
    }

    /// @dev Validate voters from a specific epoch. If finalization is
    ///      delayed, voters' balances may have changed since they voted.
    function _validateVoters(
        uint256 epoch,
        uint256 maxBatch
    ) internal {
        address[] storage voters = epochVoters[epoch];
        uint256 cursor = validationCursor[epoch];
        EpochInfo storage e = epochInfoStorage[epoch];

        uint256 processed;

        while (processed < maxBatch && cursor < voters.length) {
            address voter = voters[cursor];
            uint256 currentBal = SBF_BMX.balanceOf(voter);
            UserVote storage uv = userVotes[epoch][voter];

            if (currentBal < uv.weight) {
                uint256 diff = uv.weight - currentBal;
                e.optionWeights[uv.option - 1] -= diff;
                e.totalVoteWeight -= diff;
                uv.weight = currentBal.toUint248();
            }

            unchecked {
                ++cursor;
                ++processed;
            }
        }

        validationCursor[epoch] = cursor;
    }

    function _isOptionEligible(
        uint8 option,
        uint256 epoch
    ) internal view returns (bool) {
        uint256 idx = uint256(option) - 1;
        return lastIneligibleEpoch[idx] != epoch;
    }

    function _updateConsecutiveWins(
        uint8 winner,
        uint256 epoch
    ) internal {
        uint256 winIdx = uint256(winner) - 1;

        for (uint8 i = 0; i < NUM_OPTIONS;) {
            if (i == winIdx) {
                consecutiveWinCount[i]++;
                if (consecutiveWinCount[i] >= MAX_CONSECUTIVE_WINS) {
                    lastIneligibleEpoch[i] = epoch + 1;
                    consecutiveWinCount[i] = 0;
                }
            } else {
                consecutiveWinCount[i] = 0;
            }
            unchecked {
                ++i;
            }
        }
    }

    // V4_SWAP: SWAP_EXACT_IN_SINGLE + SETTLE(payerIsUser=false) + TAKE_ALL
    // WETH is unwrapped before the swap and ETH is sent.
    function _swapRaiseTokenForBmx(
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) internal returns (uint256) {
        uint256 bmxBefore = IERC20(BMX).balanceOf(recipient);

        IWETH(WETH).withdraw(amountIn);

        // zeroForOne = true: selling ETH (currency0) for BMX (currency1)
        bytes memory swapActions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_ALL));
        bytes[] memory swapParams = new bytes[](3);
        swapParams[0] = abi.encode(
            address(0),
            BMX,
            POOL_FEE,
            POOL_TICK_SPACING,
            POOL_HOOKS,
            true,
            amountIn.toUint128(),
            amountOutMin.toUint128(),
            ""
        );
        swapParams[1] = abi.encode(address(0), amountIn, false);
        swapParams[2] = abi.encode(BMX, amountOutMin);

        bytes memory commands = abi.encodePacked(UR_V4_SWAP);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(swapActions, swapParams);

        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: amountIn}(commands, inputs, deadline);

        return IERC20(BMX).balanceOf(recipient) - bmxBefore;
    }

    function _executeBuyBurnBmx(
        uint256 raiseAmount,
        uint256 amountOutMin,
        uint256 deadline
    ) internal {
        uint256 bmxReceived = _swapRaiseTokenForBmx(raiseAmount, amountOutMin, address(this), deadline);
        IERC20(BMX).safeTransfer(DEAD_ADDRESS, bmxReceived);
    }

    // V4_POSITION_MANAGER_CALL: MINT_POSITION + SETTLE_PAIR + SWEEP
    // Uses native ETH for the WETH half of the LP position.
    function _executeBuyBurnLp(
        uint256 raiseAmount,
        uint256 amountOutMin,
        uint256 liquidity,
        uint256 deadline
    ) internal {
        uint256 halfForBmx = raiseAmount / 2;
        uint256 halfForEth = raiseAmount - halfForBmx;
        uint256 bmxReceived = _swapRaiseTokenForBmx(halfForBmx, amountOutMin, address(this), deadline);
        uint256 tokenId = IV4PositionManager(V4_POSITION_MANAGER).nextTokenId();

        IERC20(BMX).safeTransfer(UNIVERSAL_ROUTER, bmxReceived);
        IWETH(WETH).withdraw(halfForEth);

        // MINT_POSITION + SETTLE_PAIR + SWEEP
        bytes memory mintActions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory mintParams = new bytes[](3);
        // Pool key: address(0) = ETH (currency0), BMX (currency1)
        mintParams[0] = abi.encode(
            address(0),
            BMX,
            POOL_FEE,
            POOL_TICK_SPACING,
            POOL_HOOKS,
            int24(-887220),
            int24(887220),
            liquidity,
            halfForEth.toUint128(),
            bmxReceived.toUint128(),
            lpLocker,
            ""
        );
        mintParams[1] = abi.encode(address(0), BMX);
        mintParams[2] = abi.encode(address(0), address(this));

        bytes memory pmCalldata = abi.encodeCall(
            IV4PositionManager.modifyLiquidities, (abi.encode(mintActions, mintParams), deadline)
        );

        bytes memory commands = abi.encodePacked(UR_V4_POSITION_MANAGER_CALL);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(pmCalldata);

        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: halfForEth}(commands, inputs, deadline);

        ILPLocker(lpLocker).lockPosition(tokenId);

        // Dust cleanup
        uint256 bmxDust = IERC20(BMX).balanceOf(address(this));
        if (bmxDust > 0) IERC20(BMX).safeTransfer(DEAD_ADDRESS, bmxDust);
        uint256 ethDust = address(this).balance;
        if (ethDust > 0) {
            IWETH(WETH).deposit{value: ethDust}();
            IERC20(WETH).safeTransfer(treasury, ethDust);
        }
    }

    // Epoch 0 falls back to treasury (no prior-epoch voters exist)
    function _executeParticipation(
        uint256 epoch,
        uint256 raiseAmount,
        uint256 amountOutMin,
        uint256 deadline
    ) internal {
        if (epoch == 0) {
            IERC20(WETH).safeTransfer(treasury, raiseAmount);
            return;
        }
        uint256 bmxReceived = _swapRaiseTokenForBmx(raiseAmount, amountOutMin, address(this), deadline);
        IERC20(BMX).forceApprove(participationDistributor, bmxReceived);
        IParticipationDistributor(participationDistributor).createStream(epoch, bmxReceived);
    }
}

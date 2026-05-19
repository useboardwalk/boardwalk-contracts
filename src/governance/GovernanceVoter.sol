// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Timelocked} from "../base/Timelocked.sol";
import {IRewardTracker} from "../interfaces/IRewardTracker.sol";
import {IParticipationDistributor} from "../interfaces/IParticipationDistributor.sol";
import {IUniversalRouter} from "../interfaces/IUniversalRouter.sol";
import {IV4PositionManager} from "../interfaces/IV4PositionManager.sol";
import {ILPLocker} from "../interfaces/ILPLocker.sol";
import {IWETH} from "../interfaces/IWETH.sol";

/// @title GovernanceVoter
/// @notice Merged voter + executor + vault for the 70% governance share of protocol revenue.
/// @dev Advance voting: votes in epoch N decide the winner of epoch N+1 (epoch 0 defaults to treasury).
///      Sequential finalization: N-1 must be finalized AND executed before N. `accountedBudget` prevents
///      the same WETH balance from being assigned twice when the keeper catches up on multiple epochs.
contract GovernanceVoter is Ownable2Step, Timelocked {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

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
    bytes32 public constant ACTION_SET_FEE_COLLECTOR = keccak256("SET_FEE_COLLECTOR");

    uint8 public constant OPTION_TREASURY = 1;
    uint8 public constant OPTION_BUY_BURN_BMX = 2;
    uint8 public constant OPTION_BUY_BURN_LP = 3;
    uint8 public constant OPTION_PARTICIPATION = 4;
    uint8 private constant NUM_OPTIONS = 4;

    bytes1 private constant UR_V4_SWAP = 0x10;

    IRewardTracker public immutable SBF_BMX;
    IRewardTracker public immutable STAKED_BMX_TRACKER;
    address public immutable BN_BMX;
    address public immutable BMX;
    address public immutable WETH;
    address public immutable UNIVERSAL_ROUTER;
    address public immutable V4_POSITION_MANAGER;
    uint256 public immutable EPOCH_ZERO;
    uint256 public immutable EPOCH_DURATION;

    uint24 public immutable POOL_FEE;
    int24 public immutable POOL_TICK_SPACING;
    address public immutable POOL_HOOKS;

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

    address public treasury;
    address public keeper;
    address public fallbackTreasury;
    uint256 public governanceBurnAmount;

    address public lpLocker;
    address public participationDistributor;
    address public feeCollector;
    bool public peersInitialized;

    mapping(uint256 => uint256) public epochRevenue;
    mapping(uint256 => uint256) public finalizedAt;

    /// @notice Sum of budgets for finalized-but-not-executed epochs.
    uint256 public accountedBudget;

    mapping(uint256 => EpochInfo) public epochInfoStorage;
    mapping(uint256 => mapping(address => UserVote)) public userVotes;
    uint256[4] public consecutiveWinCount;
    uint256[4] public lastIneligibleEpoch;
    uint256 public lastFinalizedEpoch;

    mapping(uint256 => address[]) internal epochVoters;
    mapping(uint256 => uint256) internal validationCursor;
    bool public finalizationInProgress;
    uint256 private finalizingEpoch;

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
    error NotFeeCollector();

    event Voted(uint256 indexed epoch, address indexed voter, uint8 option, uint256 weight);
    event EpochFinalized(uint256 indexed epoch, uint8 winningOption, bool quorumMet, uint256 budget);
    event EpochExecuted(
        uint256 indexed epoch, uint8 option, uint256 raiseTokenAmount, bool forced, address destination
    );
    event GovernanceBurnChanged(uint256 oldAmount, uint256 newAmount);
    event TreasuryChanged(address oldAddress, address newAddress);
    event KeeperChanged(address oldKeeper, address newKeeper);
    event FallbackTreasuryChanged(address oldAddress, address newAddress);
    event PeersInitialized(address lpLocker, address participationDistributor, address feeCollector);
    event RevenueDeposited(uint256 indexed epoch, uint256 amount);
    event FeeCollectorChanged(address oldFeeCollector, address newFeeCollector);

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

        // Sentinel: no real epoch number will match, so every option starts eligible.
        lastIneligibleEpoch[0] = type(uint256).max;
        lastIneligibleEpoch[1] = type(uint256).max;
        lastIneligibleEpoch[2] = type(uint256).max;
        lastIneligibleEpoch[3] = type(uint256).max;
    }

    /// @dev Accepts native ETH from WETH.withdraw() and PositionManager SWEEP only.
    receive() external payable {
        if (msg.sender != WETH && msg.sender != V4_POSITION_MANAGER) revert OnlyWETH();
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeper();
        _;
    }

    /// @notice Wire peer contracts. One-shot after deployment; both peers must point back at this contract.
    function initializePeers(
        address _lpLocker,
        address _participationDistributor,
        address _feeCollector
    ) external onlyOwner {
        if (peersInitialized) revert PeersAlreadyInitialized();
        if (_lpLocker == address(0) || _participationDistributor == address(0) || _feeCollector == address(0)) {
            revert ZeroAddress();
        }
        if (ILPLocker(_lpLocker).GOVERNANCE_VOTER() != address(this)) revert PeerWiringMismatch();
        if (IParticipationDistributor(_participationDistributor).GOVERNANCE_VOTER() != address(this)) {
            revert PeerWiringMismatch();
        }
        lpLocker = _lpLocker;
        participationDistributor = _participationDistributor;
        feeCollector = _feeCollector;
        peersInitialized = true;
        emit PeersInitialized(_lpLocker, _participationDistributor, _feeCollector);
    }

    /// @notice Pull `amount` WETH from `feeCollector` and credit it to the current epoch's
    ///         revenue bucket. Caller must have pre-approved this contract for `amount`.
    function depositRevenue(
        uint256 amount
    ) external {
        if (msg.sender != feeCollector) revert NotFeeCollector();
        IERC20(WETH).safeTransferFrom(msg.sender, address(this), amount);
        uint256 e = currentEpoch();
        epochRevenue[e] += amount;
        emit RevenueDeposited(e, amount);
    }

    /// @notice Cast a vote for the current epoch. Advance voting: vote in epoch N directs fees for epoch N+1.
    ///         Options: 1=Treasury, 2=BuyBurnBMX, 3=BuyBurnLP, 4=Participation.
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

    /// @notice Finalize an epoch after it ends. Re-validates prior-epoch voters in batches; call
    ///         repeatedly until `validationCursor[epoch-1]` reaches the end.
    function finalize(
        uint256 epoch,
        uint256 maxBatch
    ) external onlyKeeperOrOwner {
        if (maxBatch == 0) revert ZeroBatch();

        EpochInfo storage e = epochInfoStorage[epoch];
        if (e.finalized) revert EpochAlreadyFinalized();
        if (epoch >= currentEpoch()) revert EpochNotExecutable();

        if (!finalizationInProgress) {
            if (epoch > 0) {
                EpochInfo storage prev = epochInfoStorage[epoch - 1];
                if (!prev.finalized || !prev.executed) revert PreviousEpochNotExecuted();
            }
            finalizationInProgress = true;
            finalizingEpoch = epoch;

            // Budget = WETH deposited during this epoch's window. Set once on first batch.
            e.budget = epochRevenue[epoch];
            accountedBudget += e.budget;
        } else {
            if (finalizingEpoch != epoch) revert WrongFinalizeEpoch();
        }

        if (epoch > 0) {
            _validateVoters(epoch - 1, maxBatch);
            if (validationCursor[epoch - 1] < epochVoters[epoch - 1].length) return;
        }

        finalizationInProgress = false;

        (uint8 winner, bool quorumMet) = _determineWinner(epoch);
        e.winningOption = winner;
        e.finalized = true;
        // `forceMarkExecuted` measures FORCE_EXECUTE_DELAY from this timestamp.
        finalizedAt[epoch] = block.timestamp;

        _primeEpoch(epoch + 1);

        lastFinalizedEpoch = epoch;

        emit EpochFinalized(epoch, winner, quorumMet, e.budget);
    }

    /// @notice Execute the winning option for a finalized epoch.
    /// @param liquidity Liquidity parameter for Option 3 (BuyBurnLP); ignored otherwise.
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

    /// @notice Deadlock resolver. After `FORCE_EXECUTE_DELAY` past finalize, anyone can mark a
    ///         stuck epoch as executed and route its budget to `fallbackTreasury`.
    function forceMarkExecuted(
        uint256 epoch
    ) external {
        EpochInfo storage e = epochInfoStorage[epoch];
        if (!e.finalized) revert EpochNotFinalized();
        if (e.executed) revert EpochAlreadyExecuted();

        if (block.timestamp < finalizedAt[epoch] + FORCE_EXECUTE_DELAY) revert EpochNotOverdue();

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

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - EPOCH_ZERO) / EPOCH_DURATION;
    }

    function getEpochInfo(
        uint256 epoch
    ) external view returns (EpochInfo memory) {
        return epochInfoStorage[epoch];
    }

    function getUserVote(
        uint256 epoch,
        address user
    ) external view returns (UserVote memory) {
        return userVotes[epoch][user];
    }

    function isOptionEligible(
        uint8 option
    ) external view returns (bool) {
        return _isOptionEligible(option, currentEpoch());
    }

    function getEpochVoters(
        uint256 epoch
    ) external view returns (address[] memory) {
        return epochVoters[epoch];
    }

    function _authAdmin(
        bytes32
    ) internal override onlyOwner {}

    /// @dev `_burnDelay` is deliberately not overridden; delegating to `_actionDelay` gives governance
    ///      actions a 21-day burn delay and all other actions a 7-day burn delay.
    function _actionDelay(
        bytes32 action
    ) internal view override returns (uint256) {
        if (action == ACTION_SET_GOVERNANCE_BURN || action == ACTION_SET_FALLBACK_TREASURY) {
            return GOVERNANCE_TIMELOCK_DELAY;
        }
        return TIMELOCK_DELAY;
    }

    function executeSetGovernanceBurn(
        uint256 _amount
    ) external {
        _execute(ACTION_SET_GOVERNANCE_BURN, keccak256(abi.encode(_amount)));
        if (_amount > MAX_GOVERNANCE_BURN) revert GovernanceBurnOutOfRange(_amount);
        emit GovernanceBurnChanged(governanceBurnAmount, _amount);
        governanceBurnAmount = _amount;
    }

    function executeSetTreasury(
        address _treasury
    ) external {
        _executeNonZeroAddress(ACTION_SET_TREASURY, _treasury);
        emit TreasuryChanged(treasury, _treasury);
        treasury = _treasury;
    }

    function executeSetKeeper(
        address _keeper
    ) external {
        _executeNonZeroAddress(ACTION_SET_KEEPER, _keeper);
        emit KeeperChanged(keeper, _keeper);
        keeper = _keeper;
    }

    /// @notice Rotate the `feeCollector` address authorized to call `depositRevenue`.
    function executeSetFeeCollector(
        address _newFeeCollector
    ) external {
        _executeNonZeroAddress(ACTION_SET_FEE_COLLECTOR, _newFeeCollector);
        emit FeeCollectorChanged(feeCollector, _newFeeCollector);
        feeCollector = _newFeeCollector;
    }

    function executeSetFallbackTreasury(
        address _fallbackTreasury
    ) external {
        _executeNonZeroAddress(ACTION_SET_FALLBACK_TREASURY, _fallbackTreasury);
        emit FallbackTreasuryChanged(fallbackTreasury, _fallbackTreasury);
        fallbackTreasury = _fallbackTreasury;
    }

    function _executeNonZeroAddress(
        bytes32 action,
        address addr
    ) internal {
        _execute(action, keccak256(abi.encode(addr)));
        if (addr == address(0)) revert ZeroAddress();
    }

    function _determineWinner(
        uint256 epoch
    ) internal returns (uint8 winner, bool quorumMet) {
        if (epoch == 0) {
            return (OPTION_TREASURY, false);
        }

        EpochInfo storage votingEpoch = epochInfoStorage[epoch - 1];

        // Sum eligible-only weight and pick the plurality winner. Ineligible options'
        // weights are excluded from `eligibleVoteWeight` so they can't satisfy quorum on
        // behalf of an eligible minority.
        uint256 highestWeight;
        uint256 eligibleVoteWeight;
        for (uint8 i = 0; i < NUM_OPTIONS;) {
            if (_isOptionEligible(i + 1, epoch)) {
                uint256 w = votingEpoch.optionWeights[i];
                eligibleVoteWeight += w;
                if (w > highestWeight) {
                    highestWeight = w;
                    winner = i + 1;
                }
            }
            unchecked {
                ++i;
            }
        }

        // Quorum base = max(snapshot, liveSupply).
        uint256 liveSupply = SBF_BMX.totalSupply();
        uint256 quorumBase = votingEpoch.snapshotTotalWeight > liveSupply ? votingEpoch.snapshotTotalWeight : liveSupply;

        quorumMet = quorumBase > 0 && votingEpoch.snapshotSet && eligibleVoteWeight > 0
            && eligibleVoteWeight * BPS_DENOMINATOR >= quorumBase * QUORUM_BPS;

        if (!quorumMet) {
            for (uint8 i = 0; i < NUM_OPTIONS;) {
                consecutiveWinCount[i] = 0;
                unchecked {
                    ++i;
                }
            }
            return (OPTION_TREASURY, false);
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

    /// @dev If finalization is delayed, a voter's sbfBMX balance may have dropped since they voted.
    ///      Reduce their weight (and the option's weight) to the live balance; never inflate.
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

    /// @dev v4 pools use native ETH, so WETH is unwrapped before the swap and ETH is forwarded via msg.value.
    ///      Action path: SWAP_EXACT_IN_SINGLE + SETTLE(payerIsUser=false) + TAKE_ALL.
    function _swapRaiseTokenForBmx(
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient,
        uint256 deadline
    ) internal returns (uint256) {
        uint256 bmxBefore = IERC20(BMX).balanceOf(recipient);

        IWETH(WETH).withdraw(amountIn);

        // zeroForOne=true: ETH is currency0 (address(0) sorts below BMX).
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

    /// @dev Mints an ETH/BMX v4 LP position by calling PositionManager directly.
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

        IERC20(BMX).safeTransfer(V4_POSITION_MANAGER, bmxReceived);
        IWETH(WETH).withdraw(halfForEth);

        bytes memory mintActions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );
        bytes[] memory mintParams = new bytes[](5);
        mintParams[0] = abi.encode(
            address(0),
            BMX,
            POOL_FEE,
            POOL_TICK_SPACING,
            POOL_HOOKS,
            TickMath.minUsableTick(POOL_TICK_SPACING),
            TickMath.maxUsableTick(POOL_TICK_SPACING),
            liquidity,
            halfForEth.toUint128(),
            bmxReceived.toUint128(),
            lpLocker,
            ""
        );
        mintParams[1] = abi.encode(Currency.wrap(address(0)), ActionConstants.OPEN_DELTA, false);
        mintParams[2] = abi.encode(Currency.wrap(BMX), ActionConstants.OPEN_DELTA, false);
        mintParams[3] = abi.encode(Currency.wrap(address(0)), address(this));
        mintParams[4] = abi.encode(Currency.wrap(BMX), address(this));

        IV4PositionManager(V4_POSITION_MANAGER).modifyLiquidities{value: halfForEth}(
            abi.encode(mintActions, mintParams), deadline
        );

        ILPLocker(lpLocker).lockPosition(tokenId);

        uint256 bmxDust = IERC20(BMX).balanceOf(address(this));
        if (bmxDust > 0) IERC20(BMX).safeTransfer(DEAD_ADDRESS, bmxDust);
        uint256 ethDust = address(this).balance;
        if (ethDust > 0) {
            IWETH(WETH).deposit{value: ethDust}();
            IERC20(WETH).safeTransfer(treasury, ethDust);
        }
    }

    /// @dev Epoch 0 falls back to treasury; no prior-epoch voters exist to stream to.
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

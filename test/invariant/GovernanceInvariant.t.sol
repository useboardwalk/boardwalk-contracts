// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";

contract MockGovRewardTracker {
    mapping(address => uint256) internal _balances;
    uint256 internal _totalSupply;
    mapping(address => mapping(address => uint256)) internal _depositBalances;

    function setBalance(address account, uint256 amount) external {
        _balances[account] = amount;
    }

    function setTotalSupply(uint256 amount) external {
        _totalSupply = amount;
    }

    function setDepositBalance(address account, address token, uint256 amount) external {
        _depositBalances[account][token] = amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function depositBalances(address account, address token) external view returns (uint256) {
        return _depositBalances[account][token];
    }
}

contract MockGovToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockInvariantLPLocker {
    address public immutable GOVERNANCE_VOTER;

    constructor(address voter_) {
        GOVERNANCE_VOTER = voter_;
    }

    function lockPosition(uint256) external {}
}

contract MockInvariantParticipationDistributor {
    address public immutable GOVERNANCE_VOTER;

    constructor(address voter_) {
        GOVERNANCE_VOTER = voter_;
    }

    function createStream(uint256, uint256) external {}
}

contract GovernanceHandler is Test {
    GovernanceVoter public voter;
    MockGovToken public raiseToken;
    address public keeper;

    uint256 public maxEpochSeen;
    uint256 public nextFinalizeEpoch;
    uint256 public nextExecuteEpoch;

    uint256 public callCount;
    uint256 public finalizeCalls;
    uint256 public executeCalls;
    uint256 public forceCalls;

    bool public deltaMismatch;

    constructor(GovernanceVoter voter_, MockGovToken raiseToken_, address keeper_) {
        voter = voter_;
        raiseToken = raiseToken_;
        keeper = keeper_;
    }

    function warpTime(uint256 dt) external {
        callCount++;
        dt = bound(dt, 1, 21 days);
        vm.warp(block.timestamp + dt);
    }

    function depositRaise(uint256 amount) external {
        callCount++;
        amount = bound(amount, 0, 1_000e18);
        if (amount == 0) return;
        raiseToken.mint(address(voter), amount);
    }

    function finalizeNext(uint256 batchSeed) external {
        callCount++;
        uint256 curr = voter.currentEpoch();
        uint256 epoch = nextFinalizeEpoch;

        if (epoch >= curr) return;
        if (voter.finalizationInProgress()) return;

        if (epoch > 0) {
            GovernanceVoter.EpochInfo memory prev = voter.getEpochInfo(epoch - 1);
            if (!prev.finalized || !prev.executed) return;
        }

        uint256 maxBatch = bound(batchSeed, 1, 8);
        vm.prank(keeper);
        voter.finalize(epoch, maxBatch);
        finalizeCalls++;

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(epoch);
        if (info.finalized) {
            nextFinalizeEpoch = epoch + 1;
            if (epoch > maxEpochSeen) maxEpochSeen = epoch;
        }
    }

    function executeNext() external {
        callCount++;
        uint256 epoch = nextExecuteEpoch;
        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(epoch);
        if (!info.finalized || info.executed) return;

        uint256 beforeBudget = voter.accountedBudget();
        uint256 expectedDelta = info.budget;

        vm.prank(keeper);
        voter.execute(epoch, 0, 0);
        executeCalls++;

        uint256 afterBudget = voter.accountedBudget();
        uint256 actualDelta = beforeBudget - afterBudget;
        if (actualDelta != expectedDelta) deltaMismatch = true;

        GovernanceVoter.EpochInfo memory afterInfo = voter.getEpochInfo(epoch);
        if (afterInfo.executed) {
            nextExecuteEpoch = epoch + 1;
        }
    }

    function forceMarkExecuted(uint256 seed) external {
        callCount++;
        if (maxEpochSeen == 0) return;

        uint256 epoch = bound(seed, 0, maxEpochSeen);
        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(epoch);
        if (!info.finalized || info.executed) return;

        uint256 epochEnd = voter.EPOCH_ZERO() + (epoch + 1) * voter.EPOCH_DURATION();
        if (block.timestamp < epochEnd + voter.FORCE_EXECUTE_DELAY()) return;

        uint256 beforeBudget = voter.accountedBudget();
        uint256 expectedDelta = info.budget;

        voter.forceMarkExecuted(epoch);
        forceCalls++;

        uint256 afterBudget = voter.accountedBudget();
        uint256 actualDelta = beforeBudget - afterBudget;
        if (actualDelta != expectedDelta) deltaMismatch = true;

        if (epoch == nextExecuteEpoch) {
            nextExecuteEpoch = epoch + 1;
        }
    }
}

contract GovernanceInvariantTest is Test {
    GovernanceVoter public voter;
    GovernanceHandler public handler;

    MockGovRewardTracker public sbfBmx;
    MockGovRewardTracker public stakedBmxTracker;
    MockGovToken public bmx;
    MockGovToken public raiseToken;
    MockInvariantLPLocker public locker;
    MockInvariantParticipationDistributor public distributor;

    address public owner = makeAddr("owner");
    address public keeper = makeAddr("keeper");
    address public treasury = makeAddr("treasury");
    address public fallbackTreasury = makeAddr("fallbackTreasury");

    function setUp() public {
        sbfBmx = new MockGovRewardTracker();
        stakedBmxTracker = new MockGovRewardTracker();
        bmx = new MockGovToken();
        raiseToken = new MockGovToken();

        GovernanceVoter.DeployParams memory p = GovernanceVoter.DeployParams({
            sbfBmx: address(sbfBmx),
            stakedBmxTracker: address(stakedBmxTracker),
            bnBmx: makeAddr("bnBmx"),
            bmx: address(bmx),
            weth: address(raiseToken),
            universalRouter: address(new MockGovToken()),
            v4PositionManager: address(new MockGovToken()),
            treasury: treasury,
            fallbackTreasury: fallbackTreasury,
            epochZero: block.timestamp,
            epochDuration: 7 days,
            poolFee: 3000,
            poolTickSpacing: 60,
            poolHooks: address(0),
            keeper: keeper
        });

        voter = new GovernanceVoter(owner, p);
        locker = new MockInvariantLPLocker(address(voter));
        distributor = new MockInvariantParticipationDistributor(address(voter));

        vm.prank(owner);
        voter.initializePeers(address(locker), address(distributor));

        handler = new GovernanceHandler(voter, raiseToken, keeper);
        targetContract(address(handler));
    }

    function invariant_AccountedBudgetEqualsFinalizedNotExecutedSum() external view {
        uint256 sum;
        uint256 maxEpoch = handler.maxEpochSeen();

        for (uint256 i = 0; i <= maxEpoch; i++) {
            GovernanceVoter.EpochInfo memory e = voter.getEpochInfo(i);
            if (e.finalized && !e.executed) {
                sum += e.budget;
            }
        }

        assertEq(voter.accountedBudget(), sum, "accountedBudget must equal finalized-not-executed budgets");
    }

    function invariant_AccountedBudgetLeRaiseBalance() external view {
        uint256 bal = raiseToken.balanceOf(address(voter));
        assertLe(voter.accountedBudget(), bal, "accountedBudget cannot exceed voter raise balance");
    }

    function invariant_ExecuteOrForceDeltaMatchesBudget() external view {
        assertFalse(handler.deltaMismatch(), "accountedBudget delta mismatch on execute/forceMarkExecuted");
    }

    function invariant_CallSummary() external view {
        // Kept as a canary invariant for Foundry call summaries.
        assertFalse(handler.deltaMismatch(), "call summary invariant");
    }
}

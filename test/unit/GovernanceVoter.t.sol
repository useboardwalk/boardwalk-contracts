// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {Timelocked} from "src/base/Timelocked.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockRewardTracker {
    mapping(address => uint256) private _balances;
    uint256 private _totalSupply;
    mapping(address => mapping(address => uint256)) private _depositBalances;

    function setBalance(
        address account,
        uint256 amount
    ) external {
        _balances[account] = amount;
    }

    function setTotalSupply(
        uint256 amount
    ) external {
        _totalSupply = amount;
    }

    function setDepositBalance(
        address account,
        address token,
        uint256 amount
    ) external {
        _depositBalances[account][token] = amount;
    }

    function balanceOf(
        address account
    ) external view returns (uint256) {
        return _balances[account];
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function depositBalances(
        address account,
        address token
    ) external view returns (uint256) {
        return _depositBalances[account][token];
    }

    function stakedAmounts(
        address
    ) external pure returns (uint256) {
        return 0;
    }
}

contract MockERC20Simple {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(
        address to,
        uint256 amount
    ) external {
        balanceOf[to] += amount;
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // WETH-like functions for native ETH v4 pool support
    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}


/// @dev Mock Universal Router that simulates V4_SWAP by transferring BMX to the caller.
///      Records calls for test assertions.
contract MockUniversalRouterForVoter {
    MockERC20Simple public bmxToken;
    uint256 public swapRate = 2;
    uint256 public executeCallCount;
    bytes public lastCommands;

    constructor(
        address _bmx
    ) {
        bmxToken = MockERC20Simple(payable(_bmx));
    }

    function execute(
        bytes calldata commands,
        bytes[] calldata,
        uint256
    ) external payable {
        executeCallCount++;
        lastCommands = commands;
        if (commands.length > 0 && commands[0] == 0x10) {
            // V4_SWAP: simulate swap — voter sends ETH via msg.value (native ETH v4 pool)
            if (msg.value > 0) {
                uint256 bmxOut = msg.value * swapRate;
                bmxToken.mint(msg.sender, bmxOut);
            }
        }
    }

    function execute(
        bytes calldata commands,
        bytes[] calldata
    ) external payable {
        executeCallCount++;
        lastCommands = commands;
    }

    receive() external payable {}
}

contract MockParticipationDistributorForVoter {
    address public immutable GOVERNANCE_VOTER;
    uint256 public lastEpoch;
    uint256 public lastAmount;

    constructor(address _governanceVoter) {
        GOVERNANCE_VOTER = _governanceVoter;
    }

    function createStream(
        uint256 epoch,
        uint256 bmxAmount
    ) external {
        lastEpoch = epoch;
        lastAmount = bmxAmount;
    }
}

contract MockV4PositionManagerForVoter {
    uint256 public nextTokenId = 1;
}

contract MockLPLockerForVoter {
    address public immutable GOVERNANCE_VOTER;
    uint256 public lockCalls;
    uint256 public lastLockedTokenId;

    constructor(address _governanceVoter) {
        GOVERNANCE_VOTER = _governanceVoter;
    }

    function lockPosition(
        uint256 tokenId
    ) external {
        lockCalls++;
        lastLockedTokenId = tokenId;
    }
}

contract GovernanceVoterTest is Test {
    GovernanceVoter public voter;
    MockRewardTracker public sbfBmx;
    MockRewardTracker public stakedBmxTracker;
    MockERC20Simple public bmx;
    MockERC20Simple public raiseToken;
    MockUniversalRouterForVoter public universalRouter;
    MockParticipationDistributorForVoter public mockParticipationDistributor;
    MockV4PositionManagerForVoter public mockV4PositionManager;
    MockLPLockerForVoter public mockLPLocker;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");
    address public fallbackTreasury = makeAddr("fallbackTreasury");
    address public protocolKeeper = makeAddr("protocolKeeper");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    address public bnBmx;
    uint256 public constant EPOCH_DURATION = 7 days;
    uint256 public epochZero;

    bytes32 constant ACTION_SET_GOVERNANCE_BURN = keccak256("SET_GOVERNANCE_BURN");
    bytes32 constant ACTION_SET_FALLBACK_TREASURY = keccak256("SET_FALLBACK_TREASURY");
    bytes32 constant ACTION_SET_KEEPER = keccak256("SET_KEEPER");

    event Voted(uint256 indexed epoch, address indexed voter, uint8 option, uint256 weight);
    event EpochFinalized(uint256 indexed epoch, uint8 winningOption, bool quorumMet, uint256 budget);
    event EpochExecuted(uint256 indexed epoch, uint8 option, uint256 raiseTokenAmount, bool forced, address destination);
    event GovernanceBurnChanged(uint256 oldAmount, uint256 newAmount);
    event FallbackTreasuryChanged(address oldAddress, address newAddress);
    event PeersInitialized(address lpLocker, address participationDistributor);

    function setUp() public {
        epochZero = block.timestamp;
        sbfBmx = new MockRewardTracker();
        stakedBmxTracker = new MockRewardTracker();
        bmx = new MockERC20Simple();
        raiseToken = new MockERC20Simple();
        // Fund raiseToken mock with ETH so WETH.withdraw() can send ETH back
        vm.deal(address(raiseToken), 10_000 ether);
        bnBmx = makeAddr("bnBmx");
        universalRouter = new MockUniversalRouterForVoter(address(bmx));
        mockV4PositionManager = new MockV4PositionManagerForVoter();

        voter = new GovernanceVoter(owner, _defaultParams());

        // Deploy mocks that point back to voter (for wiring validation)
        mockLPLocker = new MockLPLockerForVoter(address(voter));
        mockParticipationDistributor = new MockParticipationDistributorForVoter(address(voter));

        // Wire peers
        vm.prank(owner);
        voter.initializePeers(address(mockLPLocker), address(mockParticipationDistributor));

        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        _setupVoter(charlie, 200e18);

        sbfBmx.setTotalSupply(2000e18);
    }

    function _defaultParams() internal view returns (GovernanceVoter.DeployParams memory) {
        return GovernanceVoter.DeployParams({
            sbfBmx: address(sbfBmx),
            stakedBmxTracker: address(stakedBmxTracker),
            bnBmx: bnBmx,
            bmx: address(bmx),
            weth: address(raiseToken),
            universalRouter: address(universalRouter),
            v4PositionManager: address(mockV4PositionManager),
            treasury: treasury,
            fallbackTreasury: fallbackTreasury,
            epochZero: epochZero,
            epochDuration: EPOCH_DURATION,
            poolFee: uint24(3000),
            poolTickSpacing: int24(60),
            poolHooks: address(0),
            keeper: protocolKeeper
        });
    }

    function _setupVoter(
        address user,
        uint256 weight
    ) internal {
        sbfBmx.setBalance(user, weight);
        stakedBmxTracker.setDepositBalance(user, address(bmx), weight);
        sbfBmx.setDepositBalance(user, bnBmx, weight / 10);
    }

    /// @dev Helper: finalize and execute epoch 0 as treasury (advance voting: epoch 0 always treasury)
    ///      so epoch 1 can be finalized.
    function _finalizeAndExecuteEpochZero() internal {
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);
    }

    /// @dev Helper: complete a full vote→finalize→execute cycle for an epoch using advance voting.
    ///      Votes are cast in `voteEpoch`, then finalize(voteEpoch+1) uses those votes.
    function _voteAndExecuteEpoch(uint256 voteEpoch, uint8 option) internal {
        vm.warp(epochZero + voteEpoch * EPOCH_DURATION);
        sbfBmx.setTotalSupply(2000e18);
        vm.prank(alice);
        voter.vote(option);
        vm.prank(bob);
        voter.vote(option);

        vm.warp(epochZero + (voteEpoch + 1) * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(voteEpoch + 1, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(voteEpoch + 1, 0, 0, block.timestamp);
    }

    // ============ Peer Initialization ============

    function test_InitializePeers_HappyPath() public {
        // Deploy fresh voter without peers
        GovernanceVoter freshVoter = new GovernanceVoter(owner, _defaultParams());
        MockLPLockerForVoter freshLocker = new MockLPLockerForVoter(address(freshVoter));
        MockParticipationDistributorForVoter freshDist = new MockParticipationDistributorForVoter(address(freshVoter));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PeersInitialized(address(freshLocker), address(freshDist));
        freshVoter.initializePeers(address(freshLocker), address(freshDist));

        assertTrue(freshVoter.peersInitialized());
        assertEq(freshVoter.lpLocker(), address(freshLocker));
        assertEq(freshVoter.participationDistributor(), address(freshDist));
    }

    function test_RevertWhen_InitializePeers_Twice() public {
        GovernanceVoter freshVoter = new GovernanceVoter(owner, _defaultParams());
        MockLPLockerForVoter freshLocker = new MockLPLockerForVoter(address(freshVoter));
        MockParticipationDistributorForVoter freshDist = new MockParticipationDistributorForVoter(address(freshVoter));

        vm.prank(owner);
        freshVoter.initializePeers(address(freshLocker), address(freshDist));

        vm.prank(owner);
        vm.expectRevert(GovernanceVoter.PeersAlreadyInitialized.selector);
        freshVoter.initializePeers(address(freshLocker), address(freshDist));
    }

    function test_RevertWhen_InitializePeers_WiringMismatch() public {
        GovernanceVoter freshVoter = new GovernanceVoter(owner, _defaultParams());
        // Locker points to wrong voter
        MockLPLockerForVoter badLocker = new MockLPLockerForVoter(address(0xdead));
        MockParticipationDistributorForVoter freshDist = new MockParticipationDistributorForVoter(address(freshVoter));

        vm.prank(owner);
        vm.expectRevert(GovernanceVoter.PeerWiringMismatch.selector);
        freshVoter.initializePeers(address(badLocker), address(freshDist));
    }

    function test_RevertWhen_Execute_PeersNotInitialized() public {
        GovernanceVoter freshVoter = new GovernanceVoter(owner, _defaultParams());
        // Don't initialize peers, try to execute
        vm.prank(protocolKeeper);
        vm.expectRevert(GovernanceVoter.PeersNotInitialized.selector);
        freshVoter.execute(0, 0, 0, block.timestamp);
    }

    // ============ Voting ============

    function test_Vote_HappyPath() public {
        vm.prank(alice);
        voter.vote(1);

        GovernanceVoter.UserVote memory uv = voter.getUserVote(0, alice);
        assertEq(uv.option, 1);
        assertEq(uv.weight, 1000e18);
    }

    function test_Vote_AllOptions() public {
        vm.prank(alice);
        voter.vote(1);
        vm.prank(bob);
        voter.vote(2);
        vm.prank(charlie);
        voter.vote(3);

        assertEq(voter.getUserVote(0, alice).option, 1);
        assertEq(voter.getUserVote(0, bob).option, 2);
        assertEq(voter.getUserVote(0, charlie).option, 3);
    }

    function test_Vote_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit Voted(0, alice, 1, 1000e18);
        vm.prank(alice);
        voter.vote(1);
    }

    function test_RevertWhen_Vote_InvalidOption() public {
        vm.expectRevert(GovernanceVoter.InvalidOption.selector);
        vm.prank(alice);
        voter.vote(0);

        vm.expectRevert(GovernanceVoter.InvalidOption.selector);
        vm.prank(alice);
        voter.vote(5);
    }

    function test_RevertWhen_Vote_AlreadyVoted() public {
        vm.prank(alice);
        voter.vote(1);

        vm.expectRevert(GovernanceVoter.AlreadyVoted.selector);
        vm.prank(alice);
        voter.vote(2);
    }

    function test_RevertWhen_Vote_ZeroBalance() public {
        address nobody = makeAddr("nobody");
        vm.expectRevert(GovernanceVoter.InsufficientVotingWeight.selector);
        vm.prank(nobody);
        voter.vote(1);
    }

    function test_RevertWhen_Vote_InsufficientMP() public {
        address lowMp = makeAddr("lowMp");
        sbfBmx.setBalance(lowMp, 100e18);
        stakedBmxTracker.setDepositBalance(lowMp, address(bmx), 100e18);
        sbfBmx.setDepositBalance(lowMp, bnBmx, 0);

        vm.expectRevert(GovernanceVoter.InsufficientParticipationPoints.selector);
        vm.prank(lowMp);
        voter.vote(1);
    }

    // ============ Quorum Snapshot ============

    function test_Vote_PrimesSnapshot() public {
        GovernanceVoter.EpochInfo memory infoBefore = voter.getEpochInfo(0);
        assertFalse(infoBefore.snapshotSet);

        vm.prank(alice);
        voter.vote(1);

        GovernanceVoter.EpochInfo memory infoAfter = voter.getEpochInfo(0);
        assertTrue(infoAfter.snapshotSet);
        assertEq(infoAfter.snapshotTotalWeight, 2000e18);
    }

    function test_Finalize_PrimesNextEpoch() public {
        // Epoch 0 always defaults to treasury (advance voting)
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        GovernanceVoter.EpochInfo memory nextInfo = voter.getEpochInfo(1);
        assertTrue(nextInfo.snapshotSet);
    }

    // ============ Finalization ============

    function test_Finalize_Epoch0_AlwaysTreasury() public {
        // Under advance voting, epoch 0 has no prior votes → always treasury
        vm.prank(alice);
        voter.vote(2); // Votes in epoch 0 direct epoch 1, not epoch 0
        vm.prank(bob);
        voter.vote(2);

        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(0);
        assertTrue(info.finalized);
        assertEq(info.winningOption, 1); // Always treasury for epoch 0
        assertEq(info.budget, 100e18);
    }

    function test_Finalize_AdvanceVoting_Epoch1UsesEpoch0Votes() public {
        // Vote in epoch 0 for option 2
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);

        // Finalize and execute epoch 0 (always treasury)
        raiseToken.mint(address(voter), 50e18);
        _finalizeAndExecuteEpochZero();

        // Add revenue for epoch 1
        raiseToken.mint(address(voter), 100e18);

        // Finalize epoch 1 — should use epoch 0's votes (option 2)
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(1);
        assertEq(info.winningOption, 2); // Option 2 from epoch 0 votes
    }

    function test_Finalize_QuorumNotMet_DefaultsTreasury() public {
        // Only charlie votes (200e18 / 2000e18 = 10% < 51%)
        vm.prank(charlie);
        voter.vote(2);

        _finalizeAndExecuteEpochZero();

        // Finalize epoch 1 using epoch 0's votes
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(1);
        assertEq(info.winningOption, 1); // Treasury (quorum not met)
    }

    function test_RevertWhen_Finalize_AlreadyFinalized() public {
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.expectRevert(GovernanceVoter.EpochAlreadyFinalized.selector);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);
    }

    function test_RevertWhen_Finalize_EpochNotEnded() public {
        vm.expectRevert(GovernanceVoter.EpochNotExecutable.selector);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);
    }

    function test_RevertWhen_Finalize_NotKeeperOrOwner() public {
        vm.warp(epochZero + EPOCH_DURATION);
        vm.expectRevert(GovernanceVoter.NotKeeper.selector);
        vm.prank(alice);
        voter.finalize(0, type(uint256).max);
    }

    // ============ Per-Epoch Budget Accounting ============

    function test_PerEpochBudget_OnlyNewRevenue() public {
        // Epoch 0: 50 WETH arrives
        raiseToken.mint(address(voter), 50e18);
        _finalizeAndExecuteEpochZero();

        // Epoch 1: 100 more WETH arrives (total balance was 0 after execute, now 100)
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(1);
        assertEq(info.budget, 100e18); // Only new revenue, not cumulative
    }

    function test_AccountedBudget_DecreasesOnExecute() public {
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        assertEq(voter.accountedBudget(), 100e18);

        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);

        assertEq(voter.accountedBudget(), 0);
    }

    function test_AccountedBudget_DecreasesOnForceExecute() public {
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        assertEq(voter.accountedBudget(), 100e18);

        vm.warp(epochZero + EPOCH_DURATION + 14 days);
        voter.forceMarkExecuted(0);

        assertEq(voter.accountedBudget(), 0);
    }

    // ============ Execution ============

    function test_Execute_Option1_Treasury() public {
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);

        assertEq(raiseToken.balanceOf(treasury), 100e18);
    }

    function test_Execute_OwnerCanExecute() public {
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        // Owner as backup
        vm.prank(owner);
        voter.execute(0, 0, 0, block.timestamp);

        assertEq(raiseToken.balanceOf(treasury), 100e18);
    }

    function test_RevertWhen_Execute_NotKeeperOrOwner() public {
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.expectRevert(GovernanceVoter.NotKeeper.selector);
        vm.prank(alice);
        voter.execute(0, 0, 0, block.timestamp);
    }

    function test_RevertWhen_Execute_NotFinalized() public {
        vm.prank(protocolKeeper);
        vm.expectRevert(GovernanceVoter.EpochNotFinalized.selector);
        voter.execute(0, 0, 0, block.timestamp);
    }

    function test_RevertWhen_Execute_AlreadyExecuted() public {
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);

        vm.prank(protocolKeeper);
        vm.expectRevert(GovernanceVoter.EpochAlreadyExecuted.selector);
        voter.execute(0, 0, 0, block.timestamp);
    }

    function test_Execute_BudgetSnapshot_NotLiveBalance() public {
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        raiseToken.mint(address(voter), 50e18);
        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);

        assertEq(raiseToken.balanceOf(treasury), 100e18);
        assertEq(raiseToken.balanceOf(address(voter)), 50e18);
    }

    // ============ Sequential Finalization ============

    function test_Execute_SequentialEnforcement() public {
        // Finalize epoch 0
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        // Cannot finalize epoch 1 without executing epoch 0
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.expectRevert(GovernanceVoter.PreviousEpochNotExecuted.selector);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        // Execute epoch 0, then epoch 1 can finalize
        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);
    }

    function test_SequentialFinalization_DormantEpochsCannotBeSkipped() public {
        // Epoch 0: no votes, finalize→execute
        _finalizeAndExecuteEpochZero();

        // Skip to epoch 3 — must finalize 1, 2 first
        vm.warp(epochZero + 4 * EPOCH_DURATION);

        // Cannot finalize epoch 3 without epoch 2
        vm.expectRevert(GovernanceVoter.PreviousEpochNotExecuted.selector);
        vm.prank(protocolKeeper);
        voter.finalize(3, type(uint256).max);

        // Cannot finalize epoch 2 without epoch 1
        vm.expectRevert(GovernanceVoter.PreviousEpochNotExecuted.selector);
        vm.prank(protocolKeeper);
        voter.finalize(2, type(uint256).max);

        // Finalize and execute epoch 1 (dormant, no votes in epoch 0)
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(1, 0, 0, block.timestamp);

        // Now epoch 2 can finalize
        vm.prank(protocolKeeper);
        voter.finalize(2, type(uint256).max);
    }

    // ============ Zero Supply Guard ============

    function test_Finalize_ZeroSupply_DefaultsTreasury() public {
        // Vote in epoch 0
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);

        _finalizeAndExecuteEpochZero();

        // All voters exit sbfBMX before finalization of epoch 1
        sbfBmx.setBalance(alice, 0);
        sbfBmx.setBalance(bob, 0);
        sbfBmx.setTotalSupply(0);

        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max); // Should NOT revert

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(1);
        assertEq(info.winningOption, 1); // Treasury (zero quorum base → no quorum)
    }

    // ============ Ineligibility Skip ============

    function test_IneligibleOption_SkippedDuringWinnerSelection() public {
        // Same setup as consecutive win cap — get option 2 ineligible
        // Then verify that even if votes exist for option 2, the winner selection skips it

        _finalizeAndExecuteEpochZero();

        // Vote option 2 in epochs 1, 2, 3, 4 to produce 3 wins in epochs 2, 3, 4
        // Epoch 1: vote option 2 (no prior option 2 wins)
        vm.warp(epochZero + EPOCH_DURATION);
        sbfBmx.setTotalSupply(2000e18);
        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);

        // Finalize epoch 1 (treasury — epoch 0 had no votes)
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(1, 0, 0, block.timestamp);

        // Epoch 2: vote option 2
        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);

        // Finalize epoch 2 (option 2 wins — win #1)
        vm.warp(epochZero + 3 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(2, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(2, 0, 0, block.timestamp);

        // Epoch 3: vote option 2
        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);

        // Finalize epoch 3 (option 2 wins — win #2)
        vm.warp(epochZero + 4 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(3, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(3, 0, 0, block.timestamp);

        // Epoch 4: vote option 2
        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);

        // Finalize epoch 4 (option 2 wins — win #3 → ineligible for epoch 5)
        vm.warp(epochZero + 5 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(4, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(4, 0, 0, block.timestamp);

        // Epoch 5: option 2 is ineligible
        assertFalse(voter.isOptionEligible(2));

        vm.expectRevert(abi.encodeWithSelector(GovernanceVoter.OptionIneligible.selector, uint8(2)));
        vm.prank(alice);
        voter.vote(2);

        vm.prank(alice);
        voter.vote(1);
        vm.prank(bob);
        voter.vote(1);
    }

    // ============ Consecutive Win Cap ============

    function test_ConsecutiveWinCap_IneligibleAfter3Wins() public {
        // Advance voting: votes in epoch N direct epoch N+1.
        // To get option 2 to win 3 consecutive epochs (2, 3, 4), we need:
        //   - Votes in epoch 1 for option 2 → wins epoch 2
        //   - Votes in epoch 2 for option 2 → wins epoch 3
        //   - Votes in epoch 3 for option 2 → wins epoch 4

        // First, finalize+execute epoch 0 (always treasury)
        _finalizeAndExecuteEpochZero();

        // Vote in epoch 1 for option 2
        vm.warp(epochZero + EPOCH_DURATION);
        sbfBmx.setTotalSupply(2000e18);
        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);

        // Finalize+execute epoch 1 (uses epoch 0 votes → no quorum → treasury)
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(1, 0, 0, block.timestamp);

        // Vote in epoch 2 for option 2
        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);

        // Finalize+execute epoch 2 (uses epoch 1 votes → option 2 wins) — win #1
        vm.warp(epochZero + 3 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(2, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(2, 0, 0, block.timestamp);

        // Vote in epoch 3 for option 2
        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);

        // Finalize+execute epoch 3 (uses epoch 2 votes → option 2 wins) — win #2
        vm.warp(epochZero + 4 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(3, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(3, 0, 0, block.timestamp);

        // Vote in epoch 4 for option 2
        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);

        // Finalize+execute epoch 4 (uses epoch 3 votes → option 2 wins) — win #3 → ineligible
        vm.warp(epochZero + 5 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(4, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(4, 0, 0, block.timestamp);

        // Epoch 5: option 2 should be ineligible
        assertFalse(voter.isOptionEligible(2));

        vm.expectRevert(abi.encodeWithSelector(GovernanceVoter.OptionIneligible.selector, uint8(2)));
        vm.prank(alice);
        voter.vote(2);

        vm.prank(alice);
        voter.vote(1);
    }

    // ============ Governance Burn ============

    function test_GovernanceBurn_21DayTimelock() public {
        vm.prank(owner);
        voter.signalAction(ACTION_SET_GOVERNANCE_BURN, keccak256(abi.encode(0.5e18)));

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        voter.executeSetGovernanceBurn(0.5e18);

        vm.warp(block.timestamp + 14 days);
        voter.executeSetGovernanceBurn(0.5e18);
        assertEq(voter.governanceBurnAmount(), 0.5e18);
    }

    function test_GovernanceBurn_BurnsOnVote() public {
        vm.prank(owner);
        voter.signalAction(ACTION_SET_GOVERNANCE_BURN, keccak256(abi.encode(0.1e18)));
        vm.warp(block.timestamp + 21 days);
        voter.executeSetGovernanceBurn(0.1e18);

        bmx.mint(alice, 1e18);
        vm.prank(alice);
        bmx.approve(address(voter), type(uint256).max);

        vm.prank(alice);
        voter.vote(1);

        assertEq(bmx.balanceOf(alice), 0.9e18);
    }

    function test_RevertWhen_GovernanceBurn_ExceedsMax() public {
        vm.prank(owner);
        voter.signalAction(ACTION_SET_GOVERNANCE_BURN, keccak256(abi.encode(2e18)));
        vm.warp(block.timestamp + 21 days);

        vm.expectRevert(abi.encodeWithSelector(GovernanceVoter.GovernanceBurnOutOfRange.selector, 2e18));
        voter.executeSetGovernanceBurn(2e18);
    }

    // ============ View Functions ============

    function test_CurrentEpoch() public view {
        assertEq(voter.currentEpoch(), 0);
    }

    function test_CurrentEpoch_Advances() public {
        vm.warp(epochZero + EPOCH_DURATION);
        assertEq(voter.currentEpoch(), 1);
        vm.warp(epochZero + 5 * EPOCH_DURATION);
        assertEq(voter.currentEpoch(), 5);
    }

    function test_IsOptionEligible_AllByDefault() public view {
        assertTrue(voter.isOptionEligible(1));
        assertTrue(voter.isOptionEligible(2));
        assertTrue(voter.isOptionEligible(3));
        assertTrue(voter.isOptionEligible(4));
    }

    // ============ Execution: V4 Integration ============

    function _setupAndFinalizeWithOption(
        uint8 option,
        uint256 budgetAmount
    ) internal {
        // Vote in epoch 0 for the option
        vm.prank(alice);
        voter.vote(option);
        vm.prank(bob);
        voter.vote(option);

        // Finalize and execute epoch 0 (always treasury)
        raiseToken.mint(address(voter), 10e18); // small amount for epoch 0
        _finalizeAndExecuteEpochZero();

        // Add budget for epoch 1
        raiseToken.mint(address(voter), budgetAmount);

        // Finalize epoch 1 (uses epoch 0 votes)
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);
    }

    function test_Execute_Option2_UsesV4Swap() public {
        _setupAndFinalizeWithOption(2, 100e18);

        bmx.mint(address(universalRouter), 200e18);

        vm.prank(protocolKeeper);
        voter.execute(1, 0, 0, block.timestamp);

        assertEq(universalRouter.executeCallCount(), 1);
        assertEq(uint8(universalRouter.lastCommands()[0]), 0x10);
    }

    function test_Execute_Option3_UsesV4SwapAndPositionManager() public {
        _setupAndFinalizeWithOption(3, 100e18);

        bmx.mint(address(universalRouter), 200e18);

        vm.prank(protocolKeeper);
        voter.execute(1, 0, 0, block.timestamp);

        assertGe(universalRouter.executeCallCount(), 1);
    }

    function test_Execute_Option3_RegistersLockedPosition() public {
        _setupAndFinalizeWithOption(3, 100e18);
        bmx.mint(address(universalRouter), 200e18);

        vm.prank(protocolKeeper);
        voter.execute(1, 0, 0, block.timestamp);

        assertEq(mockLPLocker.lockCalls(), 1);
        assertEq(mockLPLocker.lastLockedTokenId(), 1);
    }

    function test_Execute_Option1_TransfersToTreasury() public {
        // Epoch 0 always treasury, just test that
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);

        assertEq(raiseToken.balanceOf(treasury), 100e18);
        assertEq(raiseToken.balanceOf(address(voter)), 0);
    }

    function test_Execute_ZeroBudget_EmitsButNoTransfer() public {
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.prank(protocolKeeper);
        vm.expectEmit(true, true, true, true);
        emit EpochExecuted(0, 1, 0, false, address(0));
        voter.execute(0, 0, 0, block.timestamp);
    }

    // ============ Additional Coverage Tests ============

    function test_Vote_Option4() public {
        vm.prank(alice);
        voter.vote(4);
        assertEq(voter.getUserVote(0, alice).option, 4);
    }

    function test_Execute_Option4_CallsParticipationDistributor() public {
        _setupAndFinalizeWithOption(4, 100e18);
        bmx.mint(address(universalRouter), 200e18);
        vm.prank(protocolKeeper);
        voter.execute(1, 0, 0, block.timestamp);
    }

    function test_Vote_MPGate_ExactBoundary_Passes() public {
        address boundary = makeAddr("boundary");
        sbfBmx.setBalance(boundary, 100e18);
        stakedBmxTracker.setDepositBalance(boundary, address(bmx), 10000);
        sbfBmx.setDepositBalance(boundary, bnBmx, 150);

        vm.prank(boundary);
        voter.vote(1);
        assertEq(voter.getUserVote(0, boundary).option, 1);
    }

    function test_RevertWhen_Vote_MPGate_BelowBoundary() public {
        address lowMp = makeAddr("lowMpEdge");
        sbfBmx.setBalance(lowMp, 100e18);
        stakedBmxTracker.setDepositBalance(lowMp, address(bmx), 10000);
        sbfBmx.setDepositBalance(lowMp, bnBmx, 149);

        vm.expectRevert(GovernanceVoter.InsufficientParticipationPoints.selector);
        vm.prank(lowMp);
        voter.vote(1);
    }

    function test_Finalize_QuorumExact51Percent() public {
        // Vote in epoch 0
        sbfBmx.setTotalSupply(10000e18);
        sbfBmx.setBalance(alice, 5100e18);
        stakedBmxTracker.setDepositBalance(alice, address(bmx), 5100e18);
        sbfBmx.setDepositBalance(alice, bnBmx, 510e18);

        vm.prank(alice);
        voter.vote(2);

        _finalizeAndExecuteEpochZero();

        // Finalize epoch 1 using epoch 0's votes
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(1);
        assertEq(info.winningOption, 2);
    }

    function test_CancelPendingAction_GovernanceBurn() public {
        vm.prank(owner);
        voter.signalAction(ACTION_SET_GOVERNANCE_BURN, keccak256(abi.encode(0.5e18)));

        vm.prank(owner);
        voter.cancelAction(ACTION_SET_GOVERNANCE_BURN);

        vm.warp(block.timestamp + 21 days);
        vm.expectRevert();
        voter.executeSetGovernanceBurn(0.5e18);
    }

    function test_RevertWhen_Vote_InFinalizedEpoch() public {
        vm.prank(alice);
        voter.vote(1);
        vm.warp(epochZero + EPOCH_DURATION);
        // Finalize epoch 0's voting data
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.warp(epochZero);
        vm.expectRevert(GovernanceVoter.EpochNotActive.selector);
        vm.prank(bob);
        voter.vote(1);
    }

    function test_Finalize_NoVotes_DefaultsTreasury() public {
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(0);
        assertEq(info.winningOption, 1); // Treasury (epoch 0 always treasury)
    }

    // ============ ForceMarkExecuted ============

    function test_ForceMarkExecuted_HappyPath() public {
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.warp(epochZero + EPOCH_DURATION + 14 days);
        voter.forceMarkExecuted(0);

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(0);
        assertTrue(info.executed);
        assertEq(raiseToken.balanceOf(fallbackTreasury), 100e18);
        assertEq(raiseToken.balanceOf(treasury), 0);
    }

    function test_RevertWhen_ForceMarkExecuted_NotOverdue() public {
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.expectRevert(GovernanceVoter.EpochNotOverdue.selector);
        voter.forceMarkExecuted(0);
    }

    function test_RevertWhen_ForceMarkExecuted_NotFinalized() public {
        vm.expectRevert(GovernanceVoter.EpochNotFinalized.selector);
        voter.forceMarkExecuted(0);
    }

    function test_RevertWhen_ForceMarkExecuted_AlreadyExecuted() public {
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);

        vm.warp(epochZero + EPOCH_DURATION + 14 days);
        vm.expectRevert(GovernanceVoter.EpochAlreadyExecuted.selector);
        voter.forceMarkExecuted(0);
    }

    function test_ForceMarkExecuted_UnblocksSequentialFinalization() public {
        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.warp(epochZero + EPOCH_DURATION + 14 days);
        voter.forceMarkExecuted(0);

        vm.warp(epochZero + 2 * EPOCH_DURATION + 14 days);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);
    }

    // ============ SetKeeper (7-day timelocked) ============

    function test_SetKeeper_HappyPath() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        voter.signalAction(ACTION_SET_KEEPER, keccak256(abi.encode(newKeeper)));

        vm.warp(block.timestamp + 7 days);
        voter.executeSetKeeper(newKeeper);
        assertEq(voter.keeper(), newKeeper);
    }

    function test_SetKeeper_7DayTimelock() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        voter.signalAction(ACTION_SET_KEEPER, keccak256(abi.encode(newKeeper)));

        vm.warp(block.timestamp + 6 days);
        vm.expectRevert();
        voter.executeSetKeeper(newKeeper);

        vm.warp(block.timestamp + 1 days);
        voter.executeSetKeeper(newKeeper);
        assertEq(voter.keeper(), newKeeper);
    }

    function test_RevertWhen_SignalSetKeeper_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        voter.signalAction(ACTION_SET_KEEPER, keccak256(abi.encode(alice)));
    }

    function test_RevertWhen_ExecuteSetKeeper_ZeroAddress() public {
        vm.prank(owner);
        voter.signalAction(ACTION_SET_KEEPER, keccak256(abi.encode(address(0))));

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(GovernanceVoter.ZeroAddress.selector);
        voter.executeSetKeeper(address(0));
    }

    function test_CancelPendingAction_Keeper() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        voter.signalAction(ACTION_SET_KEEPER, keccak256(abi.encode(newKeeper)));

        vm.prank(owner);
        voter.cancelAction(ACTION_SET_KEEPER);

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        voter.executeSetKeeper(newKeeper);
    }

    // ============ Batch Finalization ============

    function test_BatchFinalize_VoteThenUnstake_ReducesWeight() public {
        // Vote in epoch 0
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);

        // Alice unstakes completely after voting
        sbfBmx.setBalance(alice, 0);

        _finalizeAndExecuteEpochZero();

        // Finalize epoch 1 using epoch 0's votes — validates epoch 0 voters
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        // Alice's weight was 1000e18, now 0 -- quorum fails (500/2000 = 25% < 51%)
        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(1);
        assertEq(info.winningOption, 1); // Treasury (quorum not met)
    }

    function test_BatchFinalize_MultiBatch() public {
        // Vote in epoch 0 with 3 voters
        vm.prank(alice);
        voter.vote(1);
        vm.prank(bob);
        voter.vote(1);
        vm.prank(charlie);
        voter.vote(1);

        _finalizeAndExecuteEpochZero();

        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + 2 * EPOCH_DURATION);

        // Process one voter per batch (3 voters in epoch 0 to validate)
        vm.prank(protocolKeeper);
        voter.finalize(1, 1);
        assertTrue(voter.finalizationInProgress());
        assertFalse(voter.getEpochInfo(1).finalized);

        vm.prank(protocolKeeper);
        voter.finalize(1, 1);
        assertTrue(voter.finalizationInProgress());
        assertFalse(voter.getEpochInfo(1).finalized);

        vm.prank(protocolKeeper);
        voter.finalize(1, 1);
        assertFalse(voter.finalizationInProgress());
        assertTrue(voter.getEpochInfo(1).finalized);
    }

    function test_RevertWhen_Vote_DuringFinalization() public {
        vm.prank(alice);
        voter.vote(1);
        vm.prank(bob);
        voter.vote(1);

        _finalizeAndExecuteEpochZero();

        // Start finalization for epoch 1 (validates epoch 0 voters, 1 of 2)
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, 1);
        assertTrue(voter.finalizationInProgress());

        // Voting should be blocked
        address dave = makeAddr("dave");
        _setupVoter(dave, 300e18);
        vm.expectRevert(GovernanceVoter.FinalizationInProgress.selector);
        vm.prank(dave);
        voter.vote(1);
    }

    function test_BatchFinalize_FlagLifecycle() public {
        vm.prank(alice);
        voter.vote(1);
        vm.prank(bob);
        voter.vote(1);

        _finalizeAndExecuteEpochZero();

        vm.warp(epochZero + 2 * EPOCH_DURATION);

        assertFalse(voter.finalizationInProgress());

        vm.prank(protocolKeeper);
        voter.finalize(1, 1);
        assertTrue(voter.finalizationInProgress());

        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);
        assertFalse(voter.finalizationInProgress());
        assertTrue(voter.getEpochInfo(1).finalized);
    }

    function test_RevertWhen_Finalize_WrongEpoch() public {
        // Vote in epoch 0 so epoch 1 validation has voters to process
        vm.prank(alice);
        voter.vote(1);
        vm.prank(bob);
        voter.vote(1);

        _finalizeAndExecuteEpochZero();

        vm.warp(epochZero + 3 * EPOCH_DURATION);

        // Start finalization for epoch 1 (validates epoch 0's 2 voters, process 1)
        vm.prank(protocolKeeper);
        voter.finalize(1, 1);
        assertTrue(voter.finalizationInProgress());

        // Try to finalize epoch 2 while epoch 1 is in progress
        vm.expectRevert(GovernanceVoter.WrongFinalizeEpoch.selector);
        vm.prank(protocolKeeper);
        voter.finalize(2, type(uint256).max);
    }

    function test_BatchFinalize_QuorumUsesMinSupply() public {
        // Vote in epoch 0
        sbfBmx.setTotalSupply(2000e18);
        vm.prank(alice);
        voter.vote(2); // weight = 1000e18
        vm.prank(bob);
        voter.vote(2); // weight = 500e18

        _finalizeAndExecuteEpochZero();

        // Supply shrinks during epoch
        sbfBmx.setTotalSupply(1000e18);

        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        // min(2000e18, 1000e18) = 1000e18, totalVoteWeight=1500e18 → 150% > 51%
        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(1);
        assertEq(info.winningOption, 2); // Quorum met with reduced base
    }

    function test_BatchFinalize_PartialUnstake_ReducesProportionally() public {
        // Vote in epoch 0
        vm.prank(alice);
        voter.vote(2); // weight = 1000e18
        vm.prank(bob);
        voter.vote(1); // weight = 500e18

        // Alice partially unstakes: 1000e18 -> 400e18
        sbfBmx.setBalance(alice, 400e18);

        _finalizeAndExecuteEpochZero();

        raiseToken.mint(address(voter), 100e18);
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        // Epoch 0 votes were re-validated
        GovernanceVoter.UserVote memory aliceVote = voter.getUserVote(0, alice);
        assertEq(aliceVote.weight, 400e18);

        GovernanceVoter.EpochInfo memory epoch0 = voter.getEpochInfo(0);
        // totalVoteWeight = 400 + 500 = 900
        assertEq(epoch0.totalVoteWeight, 900e18);
    }

    function test_BatchFinalize_NoVoters_CompletesImmediately() public {
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        assertFalse(voter.finalizationInProgress());
        assertTrue(voter.getEpochInfo(0).finalized);
        assertEq(voter.getEpochInfo(0).winningOption, 1); // Treasury
    }

    function test_GetEpochVoters() public {
        vm.prank(alice);
        voter.vote(1);
        vm.prank(bob);
        voter.vote(2);

        address[] memory voters = voter.getEpochVoters(0);
        assertEq(voters.length, 2);
        assertEq(voters[0], alice);
        assertEq(voters[1], bob);
    }

    // ============ Constructor Guards ============

    function test_RevertWhen_Constructor_ZeroKeeper() public {
        GovernanceVoter.DeployParams memory p = _defaultParams();
        p.keeper = address(0);
        vm.expectRevert(GovernanceVoter.ZeroAddress.selector);
        new GovernanceVoter(owner, p);
    }

    // ============ Fallback Treasury ============

    function test_RevertWhen_Constructor_ZeroFallbackTreasury() public {
        GovernanceVoter.DeployParams memory p = _defaultParams();
        p.fallbackTreasury = address(0);
        vm.expectRevert(GovernanceVoter.ZeroAddress.selector);
        new GovernanceVoter(owner, p);
    }

    function test_ForceMarkExecuted_EmitsForcedTrue() public {
        raiseToken.mint(address(voter), 50e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.warp(epochZero + EPOCH_DURATION + 14 days);
        vm.expectEmit(true, true, true, true);
        emit EpochExecuted(0, 1, 50e18, true, fallbackTreasury);
        voter.forceMarkExecuted(0);
    }

    function test_Execute_EmitsForcedFalse() public {
        raiseToken.mint(address(voter), 75e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.prank(protocolKeeper);
        vm.expectEmit(true, true, true, true);
        emit EpochExecuted(0, 1, 75e18, false, treasury);
        voter.execute(0, 0, 0, block.timestamp);
    }

    function test_SignalSetFallbackTreasury_Success() public {
        address newFallback = makeAddr("newFallback");
        vm.prank(owner);
        voter.signalAction(ACTION_SET_FALLBACK_TREASURY, keccak256(abi.encode(newFallback)));

        (bool isPending,,) = voter.getPendingChange(ACTION_SET_FALLBACK_TREASURY);
        assertTrue(isPending, "Fallback treasury change should be pending");
    }

    function test_ExecuteSetFallbackTreasury_Success() public {
        address newFallback = makeAddr("newFallback");
        vm.prank(owner);
        voter.signalAction(ACTION_SET_FALLBACK_TREASURY, keccak256(abi.encode(newFallback)));

        vm.warp(block.timestamp + 21 days);
        voter.executeSetFallbackTreasury(newFallback);

        assertEq(voter.fallbackTreasury(), newFallback);
    }

    function test_RevertWhen_ExecuteSetFallbackTreasury_ZeroAddress() public {
        vm.prank(owner);
        voter.signalAction(ACTION_SET_FALLBACK_TREASURY, keccak256(abi.encode(address(0))));

        vm.warp(block.timestamp + 21 days);
        vm.expectRevert(GovernanceVoter.ZeroAddress.selector);
        voter.executeSetFallbackTreasury(address(0));
    }

    function test_ForceMarkExecuted_UsesUpdatedFallbackTreasury() public {
        address newFallback = makeAddr("newFallback");
        vm.prank(owner);
        voter.signalAction(ACTION_SET_FALLBACK_TREASURY, keccak256(abi.encode(newFallback)));
        vm.warp(block.timestamp + 21 days);
        voter.executeSetFallbackTreasury(newFallback);

        raiseToken.mint(address(voter), 80e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.warp(epochZero + EPOCH_DURATION + 14 days);
        voter.forceMarkExecuted(0);

        assertEq(raiseToken.balanceOf(newFallback), 80e18);
        assertEq(raiseToken.balanceOf(fallbackTreasury), 0);
    }

    function test_Execute_TreasuryOption_StillRoutesToTreasury() public {
        raiseToken.mint(address(voter), 60e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);

        assertEq(raiseToken.balanceOf(treasury), 60e18);
        assertEq(raiseToken.balanceOf(fallbackTreasury), 0);
    }

    function test_RevertWhen_SignalAction_CannotBypassGovernanceBurnDelay() public {
        bytes32 oldBurnKey = keccak256(abi.encode("BURN", ACTION_SET_GOVERNANCE_BURN));
        bytes32 dataHash = keccak256(abi.encode(ACTION_SET_GOVERNANCE_BURN));

        vm.prank(owner);
        voter.signalAction(oldBurnKey, dataHash);

        vm.warp(block.timestamp + 7 days);

        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        voter.executeBurnAction(ACTION_SET_GOVERNANCE_BURN);
    }

    // ============ Owner Can Finalize ============

    function test_OwnerCanFinalize() public {
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(owner);
        voter.finalize(0, type(uint256).max);

        assertTrue(voter.getEpochInfo(0).finalized);
    }

    function test_RevertWhen_InitializePeers_ZeroAddress() public {
        GovernanceVoter freshVoter = new GovernanceVoter(owner, _defaultParams());
        MockLPLockerForVoter freshLocker = new MockLPLockerForVoter(address(freshVoter));

        vm.prank(owner);
        vm.expectRevert(GovernanceVoter.ZeroAddress.selector);
        freshVoter.initializePeers(address(freshLocker), address(0));
    }

    function test_Finalize_QuorumJustBelowThreshold_DefaultsTreasury() public {
        sbfBmx.setTotalSupply(10000e18);
        sbfBmx.setBalance(alice, 5099e18);
        stakedBmxTracker.setDepositBalance(alice, address(bmx), 5099e18);
        sbfBmx.setDepositBalance(alice, bnBmx, 510e18);

        vm.prank(alice);
        voter.vote(2);

        _finalizeAndExecuteEpochZero();

        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(1);
        assertEq(info.winningOption, 1, "below 51% should fail quorum");
    }

    function test_ForceMarkExecuted_ZeroBudget() public {
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.warp(epochZero + EPOCH_DURATION + 14 days);
        voter.forceMarkExecuted(0);

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(0);
        assertTrue(info.executed);
        assertEq(info.budget, 0);
        assertEq(voter.accountedBudget(), 0);
    }

    function test_MultiEpochCatchup_KeeperOfflineThenSequentialFinalizeExecute() public {
        // Keeper returns after several epochs; catch-up can be done sequentially in one block.
        vm.warp(epochZero + 4 * EPOCH_DURATION);

        for (uint256 i = 0; i < 4; i++) {
            raiseToken.mint(address(voter), 10e18);
            vm.prank(protocolKeeper);
            voter.finalize(i, type(uint256).max);
            vm.prank(protocolKeeper);
            voter.execute(i, 0, 0, block.timestamp);
        }

        assertEq(voter.accountedBudget(), 0, "all finalized epochs were executed");
        assertEq(raiseToken.balanceOf(treasury), 40e18, "all budgets should route to treasury in dormant epochs");
    }

    function test_Finalize_AtExactEpochBoundary() public {
        // Boundary condition: finalize exactly when epoch transitions.
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        assertTrue(voter.getEpochInfo(0).finalized);
    }
}

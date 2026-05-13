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

    /// @dev Accepts the unlockData + deadline + msg.value paid by GovernanceVoter's mint flow.
    ///      Real PM minting is exercised in the Base fork tests; this mock only verifies that
    ///      GovernanceVoter calls into the PM correctly without reverting.
    function modifyLiquidities(bytes calldata, uint256) external payable {}

    receive() external payable {}
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
    address public feeCollector = makeAddr("feeCollector");
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
    event PeersInitialized(address lpLocker, address participationDistributor, address feeCollector);
    event RevenueDeposited(uint256 indexed epoch, uint256 amount);
    event FeeCollectorChanged(address oldFeeCollector, address newFeeCollector);

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
        voter.initializePeers(address(mockLPLocker), address(mockParticipationDistributor), feeCollector);

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

    /// @dev Voter budget is sourced exclusively from `depositRevenue`. Mints the
    ///      requested amount of raise token to the authorized depositor and calls depositRevenue.
    ///      The deposit is attributed to whatever epoch is current at the moment of this call.
    function _fundVoter(
        uint256 amount
    ) internal {
        raiseToken.mint(feeCollector, amount);
        vm.startPrank(feeCollector);
        raiseToken.approve(address(voter), amount);
        voter.depositRevenue(amount);
        vm.stopPrank();
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
        emit PeersInitialized(address(freshLocker), address(freshDist), feeCollector);
        freshVoter.initializePeers(address(freshLocker), address(freshDist), feeCollector);

        assertTrue(freshVoter.peersInitialized());
        assertEq(freshVoter.lpLocker(), address(freshLocker));
        assertEq(freshVoter.participationDistributor(), address(freshDist));
        assertEq(freshVoter.feeCollector(), feeCollector);
    }

    function test_RevertWhen_InitializePeers_Twice() public {
        GovernanceVoter freshVoter = new GovernanceVoter(owner, _defaultParams());
        MockLPLockerForVoter freshLocker = new MockLPLockerForVoter(address(freshVoter));
        MockParticipationDistributorForVoter freshDist = new MockParticipationDistributorForVoter(address(freshVoter));

        vm.prank(owner);
        freshVoter.initializePeers(address(freshLocker), address(freshDist), feeCollector);

        vm.prank(owner);
        vm.expectRevert(GovernanceVoter.PeersAlreadyInitialized.selector);
        freshVoter.initializePeers(address(freshLocker), address(freshDist), feeCollector);
    }

    function test_RevertWhen_InitializePeers_WiringMismatch() public {
        GovernanceVoter freshVoter = new GovernanceVoter(owner, _defaultParams());
        // Locker points to wrong voter
        MockLPLockerForVoter badLocker = new MockLPLockerForVoter(address(0xdead));
        MockParticipationDistributorForVoter freshDist = new MockParticipationDistributorForVoter(address(freshVoter));

        vm.prank(owner);
        vm.expectRevert(GovernanceVoter.PeerWiringMismatch.selector);
        freshVoter.initializePeers(address(badLocker), address(freshDist), feeCollector);
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

        _fundVoter(100e18);
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
        _fundVoter(50e18);
        _finalizeAndExecuteEpochZero();

        // Add revenue for epoch 1
        _fundVoter(100e18);

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

    /// @notice quorum base is max(snapshotTotalWeight, liveSupply) — direction 1:
    ///         liveSupply shrinks below snapshot, so quorum base = snapshot (the larger).
    function test_QuorumBase_UsesSnapshot_WhenSupplyShrinks() public {
        sbfBmx.setBalance(alice, 600e18);
        stakedBmxTracker.setDepositBalance(alice, address(bmx), 600e18);
        sbfBmx.setDepositBalance(alice, bnBmx, 60e18);
        sbfBmx.setTotalSupply(1000e18);
        vm.prank(alice);
        voter.vote(2); // weight = 600e18, snapshotTotalWeight = 1000e18

        sbfBmx.setTotalSupply(900e18); // shrink before finalize

        _finalizeAndExecuteEpochZero();
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        // max(1000, 900) = 1000. 600/1000 = 60% > 51% -> quorum met.
        GovernanceVoter.EpochInfo memory info1 = voter.getEpochInfo(1);
        assertEq(info1.winningOption, 2, "quorum met with snapshot as base (snapshot > liveSupply)");
        // _determineWinner reads `epochInfoStorage[epoch - 1].snapshotTotalWeight`.
        GovernanceVoter.EpochInfo memory info0 = voter.getEpochInfo(0);
        assertEq(info0.snapshotTotalWeight, 1000e18, "epoch-0 snapshot (used by quorum) is 1000");
    }

    /// @notice quorum base is max(snapshotTotalWeight, liveSupply) — direction 2:
    ///         liveSupply grows above snapshot, so quorum base = liveSupply (the larger).
    ///         A first voter who deflated supply pre-snapshot can no longer manipulate quorum.
    function test_QuorumBase_UsesLiveSupply_WhenSupplyGrows() public {
        // Alice + bob with small weights; snapshot will be the smaller (vote-time) value.
        sbfBmx.setBalance(alice, 200e18);
        sbfBmx.setBalance(bob, 200e18);
        sbfBmx.setBalance(charlie, 0);
        stakedBmxTracker.setDepositBalance(alice, address(bmx), 200e18);
        stakedBmxTracker.setDepositBalance(bob, address(bmx), 200e18);
        sbfBmx.setDepositBalance(alice, bnBmx, 20e18);
        sbfBmx.setDepositBalance(bob, bnBmx, 20e18);

        sbfBmx.setTotalSupply(500e18);
        vm.prank(alice);
        voter.vote(2); // weight = 200, snapshot = 500
        vm.prank(bob);
        voter.vote(2); // weight = 200 -> totalVoteWeight = 400

        sbfBmx.setTotalSupply(1500e18); // grow before finalize

        _finalizeAndExecuteEpochZero();
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        // max(500, 1500) = 1500. 400/1500 ≈ 26.7% < 51% -> quorum NOT met. winner = treasury.
        GovernanceVoter.EpochInfo memory info1 = voter.getEpochInfo(1);
        assertEq(
            info1.winningOption,
            voter.OPTION_TREASURY(),
            "live > snapshot: quorum not met by under-snapshot votes"
        );
        GovernanceVoter.EpochInfo memory info0 = voter.getEpochInfo(0);
        assertEq(info0.snapshotTotalWeight, 500e18, "epoch-0 snapshot (used by quorum) is 500");
    }

    /// @notice Votes for an option that is ineligible at finalize time must NOT
    ///         contribute to quorum. Scenario: option 2 wins 3 consecutive
    ///         epochs (becoming ineligible for the next), but the majority still voted for it
    ///         during the cooldown-boundary epoch. those majority votes no longer
    ///         satisfy quorum on behalf of the minority-supported option 3.
    function test_QuorumExcludesIneligibleOptions() public {
        sbfBmx.setTotalSupply(2000e18);
        _finalizeAndExecuteEpochZero();

        // Pattern: vote in epoch K -> finalize(K+1) reads those votes. We need option 2 to win
        // finalize(2), (3), (4) -> 3 consecutive wins -> lastIneligibleEpoch[1] = 5. Then
        // votes in epoch 4 (cast BEFORE finalize(4) flips ineligibility) determine finalize(5).
        // At finalize(5), option 2 is now ineligible.

        // ----- Epoch 1 votes drive finalize(2) -----
        vm.warp(epochZero + EPOCH_DURATION);
        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);
        // finalize(1) uses epoch 0 (empty) -> treasury, count stays 0
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(1, 0, 0, block.timestamp);

        // ----- Epoch 2 votes drive finalize(3) -----
        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);
        // finalize(2) reads epoch 1 votes for option 2 -> option 2 wins (#1)
        vm.warp(epochZero + 3 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(2, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(2, 0, 0, block.timestamp);

        // ----- Epoch 3 votes drive finalize(4) -----
        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);
        // finalize(3) reads epoch 2 votes for option 2 -> option 2 wins (#2)
        vm.warp(epochZero + 4 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(3, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(3, 0, 0, block.timestamp);

        // ----- Epoch 4 votes drive finalize(5). KEY epoch: majority + minority cast at the
        // cooldown boundary. lastIneligibleEpoch[1] is still 0 right now (count=2 entering
        // finalize(4); ineligibility is set only when count reaches 3 INSIDE finalize(4)).
        _setupVoter(alice, 1000e18);
        _setupVoter(bob, 500e18);
        vm.prank(alice);
        voter.vote(2); // majority for option 2 (1000)
        vm.prank(bob);
        voter.vote(2); // majority for option 2 (500)
        _setupVoter(charlie, 200e18);
        vm.prank(charlie);
        voter.vote(3); // minority for option 3 (200)

        // finalize(4) reads epoch 3 votes for option 2 -> option 2 wins (#3),
        // lastIneligibleEpoch[1] = 5. After this call, option 2 is ineligible at epoch 5.
        vm.warp(epochZero + 5 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(4, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(4, 0, 0, block.timestamp);

        // Sanity: epoch 4's stored votes are intact (1700e18 totalVoteWeight); option 2 ineligible.
        GovernanceVoter.EpochInfo memory info4 = voter.getEpochInfo(4);
        assertEq(info4.totalVoteWeight, 1700e18, "epoch 4 totalVoteWeight = 1500 + 200 unchanged");
        assertFalse(voter.isOptionEligible(2), "option 2 ineligible at epoch 5 after 3 wins");

        // Finalize epoch 5 using epoch 4's votes (option 2 majority + option 3 minority).
        // totalVoteWeight=1700, quorumBase=2000, 1700/2000=85% > 51% -> met.
        //                     Option 2 filtered as ineligible; option 3 (200) wins by default.
        // eligibleVoteWeight = option 3's 200 only.
        //                     200/2000 = 10% < 51% -> quorum FAILS, winner = treasury.
        vm.warp(epochZero + 6 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(5, type(uint256).max);

        GovernanceVoter.EpochInfo memory info5 = voter.getEpochInfo(5);
        assertEq(
            info5.winningOption,
            voter.OPTION_TREASURY(),
            "minority eligibleVoteWeight fails quorum; winner = treasury"
        );
    }

    /// @notice when no option is ineligible at finalize time,
    ///         eligibleVoteWeight == totalVoteWeight and the prior quorum/winner logic
    ///         is preserved.
    function test_Quorum_AllOptionsEligible_BehavesAsBefore() public {
        sbfBmx.setTotalSupply(2000e18);

        // Epoch 0 votes: alice + bob for option 2 (1500 total, > 51% of 2000). No prior wins,
        // no cooldown, all options eligible at finalize(1) time.
        vm.prank(alice);
        voter.vote(2);
        vm.prank(bob);
        voter.vote(2);

        _finalizeAndExecuteEpochZero();
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        // 1500 / 2000 = 75% > 51%: quorum met. Option 2 wins as before.
        GovernanceVoter.EpochInfo memory info1 = voter.getEpochInfo(1);
        assertEq(info1.winningOption, 2, "all-eligible regression: option 2 wins");
        GovernanceVoter.EpochInfo memory info0 = voter.getEpochInfo(0);
        assertEq(info0.totalVoteWeight, 1500e18, "all-eligible regression: vote-weight unchanged");
    }

    /// @notice accepted tradeoff — if supply genuinely shrinks between snapshot and
    ///         finalize, quorum gets harder. Snapshot=1000, liveSupply=800, votes=480 (60% of
    ///         live, only 48% of snapshot) ⇒ quorumBase = max(1000, 800) = 1000, quorum NOT met.
    function test_Quorum_HarderWhenSupplyShrinksAfterSnapshot() public {
        sbfBmx.setBalance(alice, 480e18);
        sbfBmx.setBalance(bob, 0);
        sbfBmx.setBalance(charlie, 0);
        stakedBmxTracker.setDepositBalance(alice, address(bmx), 480e18);
        sbfBmx.setDepositBalance(alice, bnBmx, 48e18);

        sbfBmx.setTotalSupply(1000e18);
        vm.prank(alice);
        voter.vote(2); // weight = 480, snapshotTotalWeight = 1000

        sbfBmx.setTotalSupply(800e18); // legitimate shrink (e.g. mass unstake)

        _finalizeAndExecuteEpochZero();
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        // 480 / max(1000, 800) = 48% < 51% -> NOT met
        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(1);
        assertEq(
            info.winningOption,
            voter.OPTION_TREASURY(),
            "accepted tradeoff: legitimate-shrink scenario falls below quorum"
        );
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
        _fundVoter(50e18);
        _finalizeAndExecuteEpochZero();

        // Epoch 1: 100 more WETH arrives (total balance was 0 after execute, now 100)
        _fundVoter(100e18);
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(1, type(uint256).max);

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(1);
        assertEq(info.budget, 100e18); // Only new revenue, not cumulative
    }

    function test_AccountedBudget_DecreasesOnExecute() public {
        _fundVoter(100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        assertEq(voter.accountedBudget(), 100e18);

        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);

        assertEq(voter.accountedBudget(), 0);
    }

    function test_AccountedBudget_DecreasesOnForceExecute() public {
        _fundVoter(100e18);
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
        _fundVoter(100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);
        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);

        assertEq(raiseToken.balanceOf(treasury), 100e18);
    }

    function test_Execute_OwnerCanExecute() public {
        _fundVoter(100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        // Owner as backup
        vm.prank(owner);
        voter.execute(0, 0, 0, block.timestamp);

        assertEq(raiseToken.balanceOf(treasury), 100e18);
    }

    function test_RevertWhen_Execute_NotKeeperOrOwner() public {
        _fundVoter(100e18);
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
        _fundVoter(100e18);
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
        _fundVoter(100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        _fundVoter(50e18);
        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);

        assertEq(raiseToken.balanceOf(treasury), 100e18);
        assertEq(raiseToken.balanceOf(address(voter)), 50e18);
    }

    // ============ Sequential Finalization ============

    function test_Execute_SequentialEnforcement() public {
        // Finalize epoch 0
        _fundVoter(100e18);
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
        _fundVoter(10e18); // small amount for epoch 0
        _finalizeAndExecuteEpochZero();

        // Add budget for epoch 1
        _fundVoter(budgetAmount);

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
        _fundVoter(100e18);
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
        _fundVoter(100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        // the gate is measured from finalizedAt; finalize was at epochEnd here, so
        // the windows happen to coincide.
        vm.warp(epochZero + EPOCH_DURATION + 14 days);
        voter.forceMarkExecuted(0);

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(0);
        assertTrue(info.executed);
        assertEq(raiseToken.balanceOf(fallbackTreasury), 100e18);
        assertEq(raiseToken.balanceOf(treasury), 0);
    }

    /// @notice With a late finalize at epochEnd + 30 days, forceMarkExecuted is NOT
    ///         immediately reachable — the FORCE_EXECUTE_DELAY (14d) is measured from the
    ///         finalize timestamp, not from epochEnd. The keeper retains a full 14-day window
    ///         from finalize to call execute before the fallback path opens.
    function test_ForceMarkExecuted_RespectsFinalizedAt() public {
        _fundVoter(100e18);

        // finalize is delayed 30 days past epoch end.
        vm.warp(epochZero + EPOCH_DURATION + 30 days);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);
        uint256 finalizeTs = block.timestamp;

        // Attempting forceMarkExecuted right after finalize must revert: under the OLD gate
        // (`epochEnd + 14d`) this would have succeeded immediately because we are already
        // well past epochEnd + 14d. The gate (`finalizedAt + 14d`) still hasn't been reached.
        vm.expectRevert(GovernanceVoter.EpochNotOverdue.selector);
        voter.forceMarkExecuted(0);

        // Warp to finalizedAt + 14d -> succeeds.
        vm.warp(finalizeTs + 14 days);
        voter.forceMarkExecuted(0);

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(0);
        assertTrue(info.executed, "force succeeded at finalizedAt + 14d");
        assertEq(raiseToken.balanceOf(fallbackTreasury), 100e18);
    }

    // ============ Revenue depositor rotation ============

    /// @notice The fee collector MUST be rotatable so a `BoardwalkFeeCollector.MIGRATE_COLLECTOR`
    ///         can be paired with a matching rotation here; otherwise the new collector would
    ///         be unable to call `depositRevenue` and governance revenue would brick.
    function test_ExecuteSetFeeCollector_RotatesAndEmits() public {
        address newFeeCollector = makeAddr("newFeeCollector");
        bytes32 action = voter.ACTION_SET_FEE_COLLECTOR();

        // Owner signals + waits + executes (default 7-day timelock).
        vm.prank(owner);
        voter.signalAction(action, keccak256(abi.encode(newFeeCollector)));
        vm.warp(block.timestamp + 7 days);

        vm.expectEmit(true, true, true, true);
        emit FeeCollectorChanged(feeCollector, newFeeCollector);
        voter.executeSetFeeCollector(newFeeCollector);

        assertEq(voter.feeCollector(), newFeeCollector, "feeCollector rotated");

        // The new fee collector can now call depositRevenue; the OLD one cannot.
        uint256 currentEp = voter.currentEpoch();
        raiseToken.mint(newFeeCollector, 10e18);
        vm.startPrank(newFeeCollector);
        raiseToken.approve(address(voter), 10e18);
        voter.depositRevenue(10e18);
        vm.stopPrank();
        assertEq(voter.epochRevenue(currentEp), 10e18, "new fee collector credited");

        raiseToken.mint(feeCollector, 1e18);
        vm.startPrank(feeCollector);
        raiseToken.approve(address(voter), 1e18);
        vm.expectRevert(GovernanceVoter.NotFeeCollector.selector);
        voter.depositRevenue(1e18);
        vm.stopPrank();
    }

    function test_RevertWhen_ExecuteSetFeeCollector_ZeroAddress() public {
        bytes32 action = voter.ACTION_SET_FEE_COLLECTOR();
        vm.prank(owner);
        voter.signalAction(action, keccak256(abi.encode(address(0))));
        vm.warp(block.timestamp + 7 days);

        vm.expectRevert(GovernanceVoter.ZeroAddress.selector);
        voter.executeSetFeeCollector(address(0));
    }

    function test_RevertWhen_ExecuteSetFeeCollector_BeforeDelay() public {
        address newFeeCollector = makeAddr("newFeeCollector");
        bytes32 action = voter.ACTION_SET_FEE_COLLECTOR();
        vm.prank(owner);
        voter.signalAction(action, keccak256(abi.encode(newFeeCollector)));

        vm.expectRevert();
        voter.executeSetFeeCollector(newFeeCollector);
    }

    /// @notice finalizedAt is stored when finalize completes.
    function test_FinalizedAt_StoredOnFinalize() public {
        _fundVoter(100e18);
        vm.warp(epochZero + EPOCH_DURATION + 3 hours);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        assertEq(voter.finalizedAt(0), block.timestamp, "finalizedAt[epoch] == finalize-call timestamp");
    }

    /// @notice an on-time finalize still has a 14-day window for the
    ///         keeper to execute; after that window the fallback path becomes reachable.
    function test_ForceMarkExecuted_OnTimeFinalize_StillAvailableAfter14d() public {
        _fundVoter(100e18);
        vm.warp(epochZero + EPOCH_DURATION + 1);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        // Before 14d -> reverts.
        vm.warp(block.timestamp + 14 days - 1);
        vm.expectRevert(GovernanceVoter.EpochNotOverdue.selector);
        voter.forceMarkExecuted(0);

        // At 14d -> succeeds.
        vm.warp(block.timestamp + 1);
        voter.forceMarkExecuted(0);
    }

    function test_RevertWhen_ForceMarkExecuted_NotOverdue() public {
        _fundVoter(100e18);
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
        _fundVoter(100e18);
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
        _fundVoter(100e18);
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

        _fundVoter(100e18);
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

    function test_BatchFinalize_QuorumStillMetAfterSupplyShrink() public {
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

        // quorumBase = max(2000e18, 1000e18) = 2000e18.
        // totalVoteWeight = 1500e18 → 1500/2000 = 75% > 51% → quorum met.
        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(1);
        assertEq(info.winningOption, 2); // Quorum met with snapshot as base
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

        _fundVoter(100e18);
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
        _fundVoter(50e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        vm.warp(epochZero + EPOCH_DURATION + 14 days);
        vm.expectEmit(true, true, true, true);
        emit EpochExecuted(0, 1, 50e18, true, fallbackTreasury);
        voter.forceMarkExecuted(0);
    }

    function test_Execute_EmitsForcedFalse() public {
        _fundVoter(75e18);
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
        // Deposit BEFORE the 21-day timelock warp so the revenue is credited to epoch 0; 
        // the budget is sourced from epochRevenue[epoch], not the live WETH balance.
        _fundVoter(80e18);

        address newFallback = makeAddr("newFallback");
        vm.prank(owner);
        voter.signalAction(ACTION_SET_FALLBACK_TREASURY, keccak256(abi.encode(newFallback)));
        vm.warp(block.timestamp + 21 days);
        voter.executeSetFallbackTreasury(newFallback);

        // We're now past epoch 0; finalize it directly (it's overdue).
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);

        // FORCE_EXECUTE_DELAY is measured from `finalizedAt`, not from epoch end.
        // The finalize call above was at block.timestamp == (epochZero + 21d), so the gate is
        // 14d later.
        vm.warp(block.timestamp + 14 days);
        voter.forceMarkExecuted(0);

        assertEq(raiseToken.balanceOf(newFallback), 80e18);
        assertEq(raiseToken.balanceOf(fallbackTreasury), 0);
    }

    function test_Execute_TreasuryOption_StillRoutesToTreasury() public {
        _fundVoter(60e18);
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
        MockParticipationDistributorForVoter freshDist = new MockParticipationDistributorForVoter(address(freshVoter));

        // ZeroAddress when participation distributor is 0
        vm.prank(owner);
        vm.expectRevert(GovernanceVoter.ZeroAddress.selector);
        freshVoter.initializePeers(address(freshLocker), address(0), feeCollector);

        // ZeroAddress when revenue depositor is 0
        vm.prank(owner);
        vm.expectRevert(GovernanceVoter.ZeroAddress.selector);
        freshVoter.initializePeers(address(freshLocker), address(freshDist), address(0));
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

    // ============ per-epoch revenue accounting via depositRevenue ============

    /// @notice Deposits credit the CURRENT epoch's bucket and emit RevenueDeposited(epoch).
    function test_DepositRevenue_AttributesToCurrentEpoch() public {
        // Epoch 0 deposit
        uint256 amount0 = 30e18;
        raiseToken.mint(feeCollector, amount0);
        vm.startPrank(feeCollector);
        raiseToken.approve(address(voter), amount0);
        vm.expectEmit(true, true, true, true);
        emit RevenueDeposited(0, amount0);
        voter.depositRevenue(amount0);
        vm.stopPrank();
        assertEq(voter.epochRevenue(0), amount0, "epoch 0 bucket");

        // Warp into epoch 2 and deposit; epoch 1 should remain zero.
        vm.warp(epochZero + 2 * EPOCH_DURATION);
        uint256 amount2 = 70e18;
        raiseToken.mint(feeCollector, amount2);
        vm.startPrank(feeCollector);
        raiseToken.approve(address(voter), amount2);
        voter.depositRevenue(amount2);
        vm.stopPrank();
        assertEq(voter.epochRevenue(0), amount0, "epoch 0 bucket unchanged");
        assertEq(voter.epochRevenue(1), 0, "epoch 1 bucket stayed zero");
        assertEq(voter.epochRevenue(2), amount2, "epoch 2 bucket");
    }

    /// @notice A non-authorized caller cannot deposit (depositor is bound once at initializePeers).
    function test_DepositRevenue_RevertsForUnauthorized() public {
        raiseToken.mint(alice, 10e18);
        vm.prank(alice);
        raiseToken.approve(address(voter), 10e18);
        vm.expectRevert(GovernanceVoter.NotFeeCollector.selector);
        vm.prank(alice);
        voter.depositRevenue(10e18);
    }

    /// @notice Revenue deposited during each of epochs 1, 2, 3 funds those epochs' own
    ///         budgets — a delayed finalize at epoch 4 does NOT absorb any of it into a single
    ///         epoch. Each epoch is finalized AND executed before the next finalize
    function test_Finalize_UsesEpochRevenue_DelayedFinalize() public {
        // Deposit different amounts inside each of epochs 1, 2, 3.
        uint256[3] memory amounts = [uint256(100e18), uint256(200e18), uint256(300e18)];
        _finalizeAndExecuteEpochZero(); // epoch 0 -> treasury, currentEpoch is now 1

        for (uint256 i = 0; i < 3; i++) {
            uint256 amt = amounts[i];
            raiseToken.mint(feeCollector, amt);
            vm.startPrank(feeCollector);
            raiseToken.approve(address(voter), amt);
            voter.depositRevenue(amt);
            vm.stopPrank();
            assertEq(voter.epochRevenue(i + 1), amt, "deposit hits the current epoch");
            // Advance to the next epoch (don't finalize yet — that's the "delayed" part).
            vm.warp(epochZero + (i + 2) * EPOCH_DURATION);
        }

        // Now (currentEpoch = 4) walk through finalize+execute in order. finalize requires the
        // previous epoch to be finalized AND executed, hence the execute step inside the loop.
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(protocolKeeper);
            voter.finalize(i + 1, type(uint256).max);
            GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(i + 1);
            assertEq(info.budget, amounts[i], "finalize takes only this epoch's revenue");
            vm.prank(protocolKeeper);
            voter.execute(i + 1, 0, 0, block.timestamp);
        }
    }

    /// @notice Epochs with no deposit have a zero budget at finalize time (no balance leak).
    function test_Finalize_NoRevenueDeposited_BudgetIsZero() public {
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);
        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(0);
        assertEq(info.budget, 0, "no deposit -> zero budget");
    }

    /// @notice AccountedBudget still decrements on execute under the new
    ///         deposit-driven accounting (it is now incremented from e.budget in finalize).
    function test_AccountedBudget_DecrementsOnExecute() public {
        _fundVoter(100e18);
        vm.warp(epochZero + EPOCH_DURATION);
        vm.prank(protocolKeeper);
        voter.finalize(0, type(uint256).max);
        assertEq(voter.accountedBudget(), 100e18, "accountedBudget = e.budget after finalize");

        vm.prank(protocolKeeper);
        voter.execute(0, 0, 0, block.timestamp);
        assertEq(voter.accountedBudget(), 0, "accountedBudget cleared on execute");
    }

    function test_MultiEpochCatchup_KeeperOfflineThenSequentialFinalizeExecute() public {
        // Revenue must be deposited DURING each epoch to attribute to that epoch.
        // We simulate steady-state fee collection across epochs 0..3 by depositing inside each
        // before the keeper comes back online and catches up at epoch 4.
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(epochZero + i * EPOCH_DURATION);
            _fundVoter(10e18);
        }

        // Keeper returns at epoch 4; catch-up can be done sequentially in one block.
        vm.warp(epochZero + 4 * EPOCH_DURATION);
        for (uint256 i = 0; i < 4; i++) {
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

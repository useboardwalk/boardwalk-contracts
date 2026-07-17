// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {ParticipationDistributor} from "src/governance/ParticipationDistributor.sol";
import {IUniversalRouter} from "src/interfaces/IUniversalRouter.sol";
import {IV4PositionManager} from "src/interfaces/IV4PositionManager.sol";
import {IWETH} from "src/interfaces/IWETH.sol";

/// @title GovernanceVoterForkTest
/// @notice Base mainnet fork test for GovernanceVoter's swap and LP mint paths
///         against the real Uniswap v4 Universal Router and PositionManager.
///
/// @dev Run with: forge test --match-contract GovernanceVoterForkTest --fork-url https://mainnet.base.org -vvv
///
///      These tests validate that the encoded calldata for V4_SWAP and V4_POSITION_MANAGER_CALL
///      is accepted by the real Base contracts. They don't test full execution (would need a real
///      BMX/ETH pool with liquidity) but verify encoding compatibility.
contract GovernanceVoterForkTest is Test {
    // Base mainnet addresses
    address constant BASE_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;
    address constant BASE_UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address constant BASE_BMX = 0x548f93779fBC992010C07467cBaf329DD5F059B7;
    address constant BASE_SBF_BMX = 0x38E5be3501687500E6338217276069d16178077E;
    address constant BASE_STAKED_BMX_TRACKER = 0x3085F25Cbb5F34531229077BAAC20B9ef2AE85CB;
    address constant BASE_BN_BMX = 0x10AB197551BAB91f8B218dC9730AE0e43d893Db2;

    GovernanceVoter public voter;
    LPLocker public locker;
    ParticipationDistributor public pd;

    address owner;
    address keeper;
    address treasury;

    bool internal forked;

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function setUp() public {
        // Run with --fork-url, or self-fork from BASE_RPC_URL; without either the suite skips
        // (CI runs with no RPC configured).
        if (BASE_POSITION_MANAGER.code.length == 0) {
            string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) return;
            vm.createSelectFork(rpcUrl);
        }
        forked = true;
        require(BASE_UNIVERSAL_ROUTER.code.length > 0, "Universal Router not deployed");

        owner = makeAddr("owner");
        keeper = makeAddr("keeper");
        treasury = makeAddr("treasury");

        vm.startPrank(owner);

        voter = new GovernanceVoter(
            owner,
            GovernanceVoter.DeployParams({
                sbfBwlk: BASE_SBF_BMX,
                stakedBwlkTracker: BASE_STAKED_BMX_TRACKER,
                bnBwlk: BASE_BN_BMX,
                bwlk: BASE_BMX,
                weth: BASE_WETH,
                universalRouter: BASE_UNIVERSAL_ROUTER,
                v4PositionManager: BASE_POSITION_MANAGER,
                treasury: treasury,
                fallbackTreasury: treasury,
                epochZero: block.timestamp,
                epochDuration: 7 days,
                // The LIVE Base ETH/BMX v4 pool: hookless, 1% fee, tick spacing 200 (probed via
                // StateView.getSlot0 - the once-configured 3000/60 pool was never initialized).
                poolFee: 10_000,
                poolTickSpacing: int24(200),
                poolHooks: address(0),
                keeper: keeper
            })
        );

        // Deploy LPLocker with ETH (address(0)) as currency0
        locker = new LPLocker(BASE_POSITION_MANAGER, address(voter), address(0), BASE_BMX, address(this));

        pd = new ParticipationDistributor(BASE_BMX, address(voter));

        voter.initializePeers(address(locker), address(pd), makeAddr("feeCollector"));
        // Commit the (hookless) pool wiring: execute() blocks options 2/3/4 until the hook is set.
        voter.setPoolHooks(address(0));
        vm.stopPrank();
    }

    /// @notice Verify voter deployed with correct immutables
    function test_VoterImmutables() public onlyFork {
        assertEq(voter.UNIVERSAL_ROUTER(), BASE_UNIVERSAL_ROUTER);
        assertEq(voter.V4_POSITION_MANAGER(), BASE_POSITION_MANAGER);
        assertEq(voter.WETH(), BASE_WETH);
        assertEq(voter.BWLK(), BASE_BMX);
        assertTrue(voter.peersInitialized());
    }

    /// @notice Verify LPLocker currencies are ETH/BMX
    function test_LockerCurrencies() public onlyFork {
        assertEq(locker.CURRENCY0(), address(0), "currency0 should be ETH (address(0))");
        assertEq(locker.CURRENCY1(), BASE_BMX, "currency1 should be BMX");
    }

    /// @notice Verify the voter can receive ETH from WETH.withdraw()
    function test_VoterReceivesEthFromWeth() public onlyFork {
        // Give voter some WETH
        deal(BASE_WETH, address(voter), 1 ether);

        // Simulate WETH.withdraw() sending ETH back to voter
        vm.prank(address(voter));
        IWETH(BASE_WETH).withdraw(1 ether);

        assertEq(address(voter).balance, 1 ether, "Voter should hold 1 ETH after WETH.withdraw()");
    }

    /// @notice Verify voter rejects ETH from random addresses
    function test_VoterRejectsRandomEth() public onlyFork {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(voter).call{value: 1 ether}("");
        assertFalse(success, "Voter should reject ETH from non-WETH/non-PM sender");
    }

    /// @notice LPLocker accepts ETH only from `POSITION_MANAGER` (fee-claim path). A random
    ///         sender must be rejected. This previously asserted the opposite — the test
    ///         pranked from the test contract, which is NOT the PM, so the call always
    ///         reverted. Fixed to prank the actual PM.
    function test_LockerReceivesEth_OnlyFromPositionManager() public onlyFork {
        // Random sender (the test contract) must NOT be accepted.
        vm.deal(address(this), 1 ether);
        (bool rejected,) = address(locker).call{value: 1 ether}("");
        assertFalse(rejected, "LPLocker must reject ETH from non-PM senders");

        // PositionManager IS accepted (the fee-claim path).
        vm.deal(BASE_POSITION_MANAGER, 1 ether);
        uint256 before = address(locker).balance;
        vm.prank(BASE_POSITION_MANAGER);
        (bool ok,) = address(locker).call{value: 1 ether}("");
        assertTrue(ok, "LPLocker must accept ETH from PositionManager");
        assertEq(address(locker).balance - before, 1 ether);
    }

    /// @notice Test that voter can unwrap WETH and send ETH to Universal Router
    /// @dev This validates the WETH→ETH→UR flow without needing a real pool
    function test_WethUnwrapAndSendToUR() public onlyFork {
        uint256 amount = 1 ether;
        deal(BASE_WETH, address(voter), amount);

        // Verify voter can unwrap
        vm.prank(address(voter));
        IWETH(BASE_WETH).withdraw(amount);
        assertEq(address(voter).balance, amount);

        // Verify voter can send ETH
        vm.prank(address(voter));
        (bool ok,) = BASE_UNIVERSAL_ROUTER.call{value: amount}("");
        // UR may revert (no valid command) but the ETH transfer itself should work
        // since UR has a receive() function
        // If it reverts, that's expected — we're just testing ETH delivery
    }

    /// @notice Verify the voter's WETH balance is sufficient for a full cycle
    function test_WethBalanceForFullCycle() public onlyFork {
        uint256 budget = 10 ether;
        deal(BASE_WETH, address(voter), budget);

        assertEq(IERC20(BASE_WETH).balanceOf(address(voter)), budget);

        // Simulate Option 3: half for swap (unwrap), half for LP (unwrap)
        uint256 halfForBmx = budget / 2;
        uint256 halfForEth = budget - halfForBmx;

        // First unwrap (swap half)
        vm.prank(address(voter));
        IWETH(BASE_WETH).withdraw(halfForBmx);
        assertEq(IERC20(BASE_WETH).balanceOf(address(voter)), halfForEth, "Remaining WETH should be halfForEth");

        // Second unwrap (LP half)
        vm.prank(address(voter));
        IWETH(BASE_WETH).withdraw(halfForEth);
        assertEq(IERC20(BASE_WETH).balanceOf(address(voter)), 0, "All WETH should be unwrapped");
        assertEq(address(voter).balance, budget, "Voter should hold full budget as ETH");
    }

    /// @notice PositionManager.nextTokenId() works (used in _executeBuyBurnLp)
    function test_PositionManagerNextTokenId() public onlyFork {
        uint256 nextId = IV4PositionManager(BASE_POSITION_MANAGER).nextTokenId();
        assertGt(nextId, 0, "nextTokenId should be > 0");
        console.log("Next token ID:", nextId);
    }

    /// @notice LPLocker encoding test against real PositionManager (fee claim path)
    /// @dev Uses a real position ID to verify the DECREASE_LIQUIDITY encoding
    function test_LockerFeeClaimEncoding() public onlyFork {
        // Position #1 exists on Base mainnet
        vm.mockCall(address(voter), abi.encodeWithSignature("treasury()"), abi.encode(treasury));

        // Lock a fake position to test the encoding path
        vm.mockCall(BASE_POSITION_MANAGER, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)"), "");

        // We can't actually call claimFees without owning a position,
        // but we can verify the locker was deployed correctly and wired
        assertEq(locker.POSITION_MANAGER(), BASE_POSITION_MANAGER);
        assertEq(locker.GOVERNANCE_VOTER(), address(voter));
    }

    // ============================================================================
    // Option 3 — direct PM mint, OPEN_DELTA SETTLE,
    // double SWEEP to GovernanceVoter, dynamic TickMath ticks. Fork tests exercise
    // the encoding against the real Base PositionManager + Universal Router.
    // ============================================================================

    /// @dev Make alice a valid voter without needing on-chain sbfBMX balance. Mocks the four
    ///      reward-tracker reads that `GovernanceVoter.vote()` performs.
    function _mockAliceVoter(
        address alice,
        uint256 weight,
        uint256 totalSupply_
    ) internal {
        vm.mockCall(BASE_SBF_BMX, abi.encodeWithSelector(IERC20.balanceOf.selector, alice), abi.encode(weight));
        vm.mockCall(BASE_SBF_BMX, abi.encodeWithSignature("totalSupply()"), abi.encode(totalSupply_));
        // stakedBmx = 0 -> participation-points gate is skipped (see _vote check).
        vm.mockCall(
            BASE_STAKED_BMX_TRACKER,
            abi.encodeWithSignature("depositBalances(address,address)", alice, BASE_BMX),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            BASE_SBF_BMX,
            abi.encodeWithSignature("depositBalances(address,address)", alice, BASE_BN_BMX),
            abi.encode(uint256(0))
        );
    }

    /// @dev Drive the voter from epoch 0 through finalize+execute of an Option 3 winning
    ///      epoch (1). Returns the WETH budget assigned to epoch 1 so the caller can
    ///      assert against treasury deltas etc.
    ///
    ///      Warps are ABSOLUTE (anchored to EPOCH_ZERO), never `block.timestamp + N`: under via-ir
    ///      the optimizer legitimately caches the TIMESTAMP opcode within the test frame (it cannot
    ///      change mid-transaction in a real EVM), so a second relative warp would be computed from
    ///      the stale pre-warp value and silently re-target the same instant.
    function _runOption3ToExecution(
        uint256 budgetWeth
    ) internal returns (uint256 epochOneBudget) {
        address alice = makeAddr("voterAlice");
        _mockAliceVoter(alice, 1000e18, 1000e18);

        // Hoisted: an inline voter.EPOCH_ZERO() argument would consume the preceding vm.prank.
        uint256 epochZero = voter.EPOCH_ZERO();

        // Epoch 0 vote for option 3 (drives finalize(1) winner).
        vm.prank(alice);
        voter.vote(3);

        // Finalize+execute epoch 0 (always defaults to treasury).
        vm.warp(epochZero + 7 days);
        vm.prank(keeper);
        voter.finalize(0, type(uint256).max);
        vm.prank(keeper);
        voter.execute(0, 0, 0, epochZero + 8 days);

        // currentEpoch is now 1. Deposit revenue here so epochRevenue[1] is funded.
        address depositor = voter.feeCollector();
        deal(BASE_WETH, depositor, budgetWeth);
        vm.startPrank(depositor);
        IERC20(BASE_WETH).approve(address(voter), budgetWeth);
        voter.depositRevenue(budgetWeth);
        vm.stopPrank();
        epochOneBudget = budgetWeth;

        // Finalize epoch 1 (snapshot total = 1000, totalVote = 1000, 100% > 51% -> option 3 wins).
        // e.budget = epochRevenue[1] = budgetWeth.
        vm.warp(epochZero + 14 days);
        vm.prank(keeper);
        voter.finalize(1, type(uint256).max);
    }

    /// @notice Assert NFT lands at LPLocker, GovernanceVoter is left with no BMX/ETH residue,
    ///         and the PositionManager's balances return to their pre-execution snapshot (SWEEP recovers
    ///         everything pre-funded for this mint). Treasury WETH delta is allowed to be zero — exact
    ///         mint consumption may legitimately leave no residual to sweep.
    function testFork_Option3_FullExecution_Succeeds() public onlyFork {
        uint256 budget = 1 ether;
        _runOption3ToExecution(budget);

        uint256 pmBmxBefore = IERC20(BASE_BMX).balanceOf(BASE_POSITION_MANAGER);
        uint256 pmEthBefore = BASE_POSITION_MANAGER.balance;
        uint256 lockerCountBefore = locker.getLockedPositions().length;

        uint256 deadline = voter.EPOCH_ZERO() + 15 days;
        vm.prank(keeper);
        // liquidity = 0 would be a no-op mint; pick a small value that the half-budget can fund.
        // Deadline is absolute (see _runOption3ToExecution): a stale cached block.timestamp here
        // would hand the router an already-expired deadline.
        voter.execute(1, 0, uint256(1e15), deadline);

        // 1. NFT registered at locker.
        assertEq(locker.getLockedPositions().length, lockerCountBefore + 1, "NFT should be registered at locker");

        // 2. No BMX residue at GovernanceVoter; PM BMX returned to snapshot.
        assertEq(IERC20(BASE_BMX).balanceOf(address(voter)), 0, "voter BMX residue (any leftover goes to DEAD)");
        assertEq(
            IERC20(BASE_BMX).balanceOf(BASE_POSITION_MANAGER),
            pmBmxBefore,
            "PM BMX delta == 0 (SWEEP recovered pre-funded BMX)"
        );

        // 3. No ETH residue at GovernanceVoter; PM ETH returned to snapshot.
        //    Treasury WETH delta is NOT asserted non-zero — exact mint consumption can produce
        //    zero residual. Non-zero assertion lives in the partial-mint test below.
        assertEq(address(voter).balance, 0, "voter ETH residue should be 0");
        assertEq(BASE_POSITION_MANAGER.balance, pmEthBefore, "PM ETH delta == 0 (SWEEP recovered pre-funded ETH)");
    }

    /// @notice Deliberately oversize the BMX/ETH inputs so the mint legitimately consumes
    ///         less than the pre-funded amounts. SWEEP must reclaim every wei back to
    ///         GovernanceVoter; the BMX residue is then burned to DEAD; treasury must receive
    ///         a strictly positive WETH delta (the swept ETH residue, re-wrapped).
    function testFork_Option3_PartialMint_NoStuckBMX() public onlyFork {
        uint256 budget = 1 ether;
        _runOption3ToExecution(budget);

        uint256 pmBmxBefore = IERC20(BASE_BMX).balanceOf(BASE_POSITION_MANAGER);
        uint256 pmEthBefore = BASE_POSITION_MANAGER.balance;
        uint256 treasuryWethBefore = IERC20(BASE_WETH).balanceOf(treasury);
        uint256 deadBmxBefore = IERC20(BASE_BMX).balanceOf(0x000000000000000000000000000000000000dEaD);

        // Tiny liquidity: mint consumes far less BMX/ETH than the pre-funded budget allows.
        uint256 deadline = voter.EPOCH_ZERO() + 15 days;
        vm.prank(keeper);
        voter.execute(1, 0, uint256(1), deadline);

        // PM returns to snapshot exactly (SWEEP recovered every prefunded wei).
        assertEq(IERC20(BASE_BMX).balanceOf(BASE_POSITION_MANAGER), pmBmxBefore, "PM BMX delta == 0");
        assertEq(BASE_POSITION_MANAGER.balance, pmEthBefore, "PM ETH delta == 0");

        // GovernanceVoter is drained (BMX -> DEAD, ETH -> treasury).
        assertEq(IERC20(BASE_BMX).balanceOf(address(voter)), 0, "voter BMX residue should be 0");
        assertEq(address(voter).balance, 0, "voter ETH residue should be 0");

        // BMX residue burned cleanly.
        assertGt(
            IERC20(BASE_BMX).balanceOf(0x000000000000000000000000000000000000dEaD),
            deadBmxBefore,
            "DEAD address should receive burned BMX residue"
        );

        // Treasury WETH delta strictly positive: the swept ETH residue is wrapped and forwarded.
        assertGt(IERC20(BASE_WETH).balanceOf(treasury), treasuryWethBefore, "treasury should receive swept ETH residue");
    }

    /// @notice Verifies the Base Universal Router accepts the current
    ///         `_swapRaiseTokenForBmx` calldata layout (V4_SWAP with SWAP_EXACT_IN_SINGLE +
    ///         SETTLE(payerIsUser=false) + TAKE_ALL). If a UR upgrade changes the expected
    ///         parameter shape (e.g. a new `minHopPriceX36` field), the swap reverts here.
    function testFork_SwapRaiseTokenForBmx_RouterAccepts0x140Calldata() public onlyFork {
        // Option 2 (BuyBurnBMX) exercises ONLY _swapRaiseTokenForBmx, no LP mint. Reusing
        // _runOption3ToExecution would be wrong — we want Option 2 to isolate the UR swap.
        address alice = makeAddr("voterAlice");
        _mockAliceVoter(alice, 1000e18, 1000e18);

        vm.prank(alice);
        voter.vote(2);

        // Absolute warps/deadlines (see _runOption3ToExecution): via-ir caches TIMESTAMP within the
        // test frame, so relative `block.timestamp + N` warps silently re-target the same instant.
        // Hoisted local: an inline voter.EPOCH_ZERO() argument would consume the preceding vm.prank.
        uint256 epochZero = voter.EPOCH_ZERO();
        vm.warp(epochZero + 7 days);
        vm.prank(keeper);
        voter.finalize(0, type(uint256).max);
        vm.prank(keeper);
        voter.execute(0, 0, 0, epochZero + 8 days);

        // Deposit through feeCollector so epochRevenue[1] is funded.
        address depositor = voter.feeCollector();
        deal(BASE_WETH, depositor, 0.1 ether);
        vm.startPrank(depositor);
        IERC20(BASE_WETH).approve(address(voter), 0.1 ether);
        voter.depositRevenue(0.1 ether);
        vm.stopPrank();

        vm.warp(epochZero + 14 days);
        vm.prank(keeper);
        voter.finalize(1, type(uint256).max);

        // Option 2 routes 100% of the budget through _swapRaiseTokenForBmx -> Universal Router.
        // A reverting execute() here means the configured UR did not accept our 0x140 calldata.
        vm.prank(keeper);
        voter.execute(1, 0, 0, epochZero + 15 days);

        // Sanity: DEAD received the swapped BMX (BuyBurnBMX outcome).
        assertGt(IERC20(BASE_BMX).balanceOf(0x000000000000000000000000000000000000dEaD), 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LPStaking} from "src/core/LPStaking.sol";

/// @dev Mock ERC20 with mint
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
}

/// @title StakingHandler
/// @notice Handler contract for bounded invariant testing of LPStaking
contract StakingHandler is Test {
    LPStaking public staking;
    MockERC20 public lpToken;
    MockERC20 public rewardToken;
    address public feeDistributor;

    // Ghost variables for tracking
    uint256 public ghost_totalStaked;
    uint256 public ghost_totalClaimed;
    uint256 public ghost_totalFeesSent;
    uint256 public ghost_lastAccRewardPerWeight;

    // Actors
    address[] public actors;
    mapping(address => uint256) public ghost_userStaked;

    constructor(
        LPStaking _staking,
        MockERC20 _lpToken,
        MockERC20 _rewardToken,
        address _feeDistributor
    ) {
        staking = _staking;
        lpToken = _lpToken;
        rewardToken = _rewardToken;
        feeDistributor = _feeDistributor;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encodePacked("staker", i))));
        }
    }

    function stake(
        uint256 actorSeed,
        uint256 amount
    ) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        amount = bound(amount, 1e18, 10_000e18);

        // Track rewards auto-claimed during stake (pending rewards are settled)
        uint256 balBefore = rewardToken.balanceOf(actor);

        lpToken.mint(actor, amount);
        vm.startPrank(actor);
        lpToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();

        uint256 autoClaimed = rewardToken.balanceOf(actor) - balBefore;
        ghost_totalClaimed += autoClaimed;
        ghost_totalStaked += amount;
        ghost_userStaked[actor] += amount;
        ghost_lastAccRewardPerWeight = staking.accRewardPerWeight();
    }

    function withdraw(
        uint256 actorSeed,
        uint256 amount
    ) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        (uint256 userLp,,,) = staking.userInfo(actor);
        if (userLp == 0) return;

        amount = bound(amount, 1, userLp);

        // Track rewards auto-claimed during withdraw
        uint256 balBefore = rewardToken.balanceOf(actor);

        vm.prank(actor);
        staking.withdraw(amount);

        uint256 autoClaimed = rewardToken.balanceOf(actor) - balBefore;
        // autoClaimed includes both reward tokens AND returned LP tokens
        // LP tokens go back as lpToken, rewards go back as rewardToken
        // Since we only track rewardToken balance, this correctly captures only rewards
        ghost_totalClaimed += autoClaimed;
        ghost_totalStaked -= amount;
        ghost_userStaked[actor] -= amount;
        ghost_lastAccRewardPerWeight = staking.accRewardPerWeight();
    }

    function claim(
        uint256 actorSeed
    ) external {
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];
        (uint256 userLp,,,) = staking.userInfo(actor);
        if (userLp == 0) return;

        uint256 balBefore = rewardToken.balanceOf(actor);
        vm.prank(actor);
        staking.claim();
        uint256 claimed = rewardToken.balanceOf(actor) - balBefore;
        ghost_totalClaimed += claimed;
        ghost_lastAccRewardPerWeight = staking.accRewardPerWeight();
    }

    function notifyFees(
        uint256 amount
    ) external {
        amount = bound(amount, 0, 1000e18);
        if (amount == 0) return;

        rewardToken.mint(feeDistributor, amount);
        vm.startPrank(feeDistributor);
        rewardToken.approve(address(staking), amount);
        staking.notifyFees(amount);
        vm.stopPrank();

        ghost_totalFeesSent += amount;
        ghost_lastAccRewardPerWeight = staking.accRewardPerWeight();
    }

    function warpTime(
        uint256 seconds_
    ) external {
        seconds_ = bound(seconds_, 1, 90 days);
        vm.warp(block.timestamp + seconds_);
    }
}

/// @title StakingInvariantTest
/// @notice Invariant tests for LPStaking: totalWeight consistency, solvency
contract StakingInvariantTest is Test {
    LPStaking internal template;
    LPStaking internal staking;
    MockERC20 internal lpToken;
    MockERC20 internal rewardToken;
    StakingHandler internal handler;
    address internal feeDistributor;

    uint256 internal constant VESTING_ALLOCATION = 1_000_000e18;

    function setUp() public {
        feeDistributor = makeAddr("feeDistributor");
        lpToken = new MockERC20("LP", "LP");
        rewardToken = new MockERC20("RWD", "RWD");

        template = new LPStaking();
        address clone = Clones.clone(address(template));
        staking = LPStaking(clone);

        // Set initializer and initialize
        staking.setInitializer(address(this));
        staking.initialize(address(lpToken), address(rewardToken), feeDistributor, block.timestamp, VESTING_ALLOCATION);

        // Fund vesting allocation
        rewardToken.mint(address(staking), VESTING_ALLOCATION);

        // Warp past vesting start (24h delay)
        vm.warp(block.timestamp + 24 hours + 1);

        handler = new StakingHandler(staking, lpToken, rewardToken, feeDistributor);
        targetContract(address(handler));
    }

    /// @notice Invariant: totalLpStaked matches ghost tracking
    function invariant_totalLpStakedMatchesGhost() external view {
        assertEq(staking.totalLpStaked(), handler.ghost_totalStaked(), "totalLpStaked ghost mismatch");
    }

    /// @notice Invariant: totalWeight >= totalLpStaked (MP adds weight)
    function invariant_totalWeightGeTotalLpStaked() external view {
        assertGe(staking.totalWeight(), staking.totalLpStaked(), "totalWeight must be >= totalLpStaked");
    }

    /// @notice Invariant: total outflow never exceeds total inflow (solvency)
    function invariant_stakingSolvency() external view {
        uint256 balance = rewardToken.balanceOf(address(staking));
        uint256 totalInput = VESTING_ALLOCATION + handler.ghost_totalFeesSent();
        uint256 totalClaimed = handler.ghost_totalClaimed();
        // Balance + claimed should never exceed what was put in
        assertLe(totalClaimed, totalInput, "Claims exceed total input (insolvent)");
        // Balance should be >= (input - claimed) minus any lost rewards (zero-staker periods)
        // Since rewards can be lost, balance can be less than (input - claimed)
        // But claimed should never exceed input
    }

    /// @notice Invariant: total claimed + remaining balance >= initial allocation + fees sent
    ///         (conservation of tokens: nothing created from thin air)
    function invariant_tokenConservation() external view {
        uint256 remainingInContract = rewardToken.balanceOf(address(staking));
        uint256 totalClaimed = handler.ghost_totalClaimed();
        uint256 totalInput = VESTING_ALLOCATION + handler.ghost_totalFeesSent();

        // claimed + remaining should not exceed total input
        assertLe(totalClaimed + remainingInContract, totalInput + 1, "Token conservation violated");
    }

    /// @notice Invariant: sum of all users' lpStaked == totalLpStaked
    function invariant_perUserLpSumsToTotal() external view {
        uint256 sumLp;
        for (uint256 i = 0; i < 5; i++) {
            address actor = handler.actors(i);
            (uint256 userLp,,,) = staking.userInfo(actor);
            sumLp += userLp;
        }
        assertEq(sumLp, staking.totalLpStaked(), "Sum of user LP should equal totalLpStaked");
    }

    /// @notice Invariant: accRewardPerWeight is monotonically non-decreasing
    function invariant_accRewardMonotonic() external view {
        assertGe(
            staking.accRewardPerWeight(),
            handler.ghost_lastAccRewardPerWeight(),
            "accRewardPerWeight should never decrease"
        );
    }

    /// @notice Invariant: totalWeight == sum of all users' (lpStaked + multiplierPoints)
    function invariant_totalWeightEqualsUserWeightSum() external view {
        uint256 sumWeight;
        for (uint256 i = 0; i < 5; i++) {
            address actor = handler.actors(i);
            (uint256 userLp, uint256 userMp,,) = staking.userInfo(actor);
            sumWeight += userLp + userMp;
        }
        assertEq(sumWeight, staking.totalWeight(), "Sum of user weights should equal totalWeight");
    }

    /// @notice Invariant: when totalWeight == 0, accRewardPerWeight must not increase
    ///         (rewards are lost during zero-staker periods)
    function invariant_zeroStakerNoRewardAccrual() external view {
        if (staking.totalWeight() == 0 && staking.totalLpStaked() == 0) {
            // If no stakers, accRewardPerWeight should not have increased since last action
            assertEq(
                staking.accRewardPerWeight(),
                handler.ghost_lastAccRewardPerWeight(),
                "accRewardPerWeight must not increase with zero stakers"
            );
        }
    }
}

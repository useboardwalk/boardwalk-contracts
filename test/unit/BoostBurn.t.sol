// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {BoostBurn} from "src/core/BoostBurn.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockBWLK {
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

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockNFT {
    mapping(address => uint256) public balanceOf;
    uint256 private _nextId;

    function mint(
        address to,
        uint256 count
    ) external {
        balanceOf[to] += count;
        _nextId += count;
    }
}

contract RevertingNFT {
    function balanceOf(
        address
    ) external pure returns (uint256) {
        revert("broken");
    }
}

contract BoostBurnTest is Test {
    BoostBurn public boostBurn;
    MockBWLK public bwlk;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public tokenA = makeAddr("tokenA");
    address public tokenB = makeAddr("tokenB");

    uint256 public constant EPOCH_DURATION = 30 days;
    uint256 public epochZero;

    bytes32 constant ACTION_SET_BWLK_COST = keccak256("SET_BWLK_COST");

    event Boosted(address indexed token, address indexed wallet, uint256 epoch, int256 newScore);
    event Deboosted(address indexed token, address indexed wallet, uint256 epoch, int256 newScore);
    event BwlkCostChanged(uint256 oldCost, uint256 newCost);

    function setUp() public {
        epochZero = block.timestamp;
        bwlk = new MockBWLK();
        boostBurn = new BoostBurn(owner, address(bwlk), epochZero, EPOCH_DURATION, address(0), 0);

        bwlk.mint(alice, 100e18);
        bwlk.mint(bob, 100e18);

        vm.prank(alice);
        bwlk.approve(address(boostBurn), type(uint256).max);
        vm.prank(bob);
        bwlk.approve(address(boostBurn), type(uint256).max);
    }

    // ============ Boost ============

    function test_Boost_IncrementsScore() public {
        vm.prank(alice);
        boostBurn.boost(tokenA);
        assertEq(boostBurn.getScore(tokenA), 1);
    }

    function test_Boost_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit Boosted(tokenA, alice, 0, 1);

        vm.prank(alice);
        boostBurn.boost(tokenA);
    }

    function test_Boost_BurnsBWLK() public {
        uint256 balBefore = bwlk.balanceOf(alice);
        vm.prank(alice);
        boostBurn.boost(tokenA);
        assertEq(bwlk.balanceOf(alice), balBefore - 0.1e18, "boost should deduct the BWLK cost");
        assertEq(bwlk.balanceOf(boostBurn.DEAD_ADDRESS()), 0.1e18, "boost should burn the BWLK to dead");
    }

    function test_Boost_MultipleUsersOnSameToken() public {
        vm.prank(alice);
        boostBurn.boost(tokenA);
        vm.prank(bob);
        boostBurn.boost(tokenA);
        assertEq(boostBurn.getScore(tokenA), 2);
    }

    function test_Boost_MultipleTokens() public {
        vm.prank(alice);
        boostBurn.boost(tokenA);
        vm.prank(alice);
        boostBurn.boost(tokenB);
        assertEq(boostBurn.getScore(tokenA), 1);
        assertEq(boostBurn.getScore(tokenB), 1);
    }

    // ============ Deboost ============

    function test_Deboost_DecrementsScore() public {
        vm.prank(alice);
        boostBurn.deboost(tokenA);
        assertEq(boostBurn.getScore(tokenA), -1);
    }

    function test_Deboost_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit Deboosted(tokenA, alice, 0, -1);

        vm.prank(alice);
        boostBurn.deboost(tokenA);
    }

    function test_Deboost_NegativeScore() public {
        vm.prank(alice);
        boostBurn.deboost(tokenA);
        vm.prank(bob);
        boostBurn.deboost(tokenA);
        assertEq(boostBurn.getScore(tokenA), -2);
    }

    function test_BoostAndDeboost_NetScore() public {
        vm.prank(alice);
        boostBurn.boost(tokenA);
        vm.prank(bob);
        boostBurn.deboost(tokenA);
        assertEq(boostBurn.getScore(tokenA), 0);
    }

    // ============ Epoch Enforcement ============

    function test_RevertWhen_SameWalletSameTokenSameEpoch() public {
        vm.prank(alice);
        boostBurn.boost(tokenA);

        vm.expectRevert(BoostBurn.AlreadyInteracted.selector);
        vm.prank(alice);
        boostBurn.boost(tokenA);
    }

    function test_RevertWhen_BoostThenDeboostSameEpoch() public {
        vm.prank(alice);
        boostBurn.boost(tokenA);

        vm.expectRevert(BoostBurn.AlreadyInteracted.selector);
        vm.prank(alice);
        boostBurn.deboost(tokenA);
    }

    function test_AllowsInteractionInNewEpoch() public {
        vm.prank(alice);
        boostBurn.boost(tokenA);
        assertEq(boostBurn.getScore(tokenA), 1);

        vm.warp(block.timestamp + EPOCH_DURATION);

        vm.prank(alice);
        boostBurn.boost(tokenA);
        assertEq(boostBurn.getScore(tokenA), 2);
    }

    function test_HasInteracted() public {
        assertFalse(boostBurn.hasInteracted(alice, tokenA, 0));

        vm.prank(alice);
        boostBurn.boost(tokenA);

        assertTrue(boostBurn.hasInteracted(alice, tokenA, 0));
        assertFalse(boostBurn.hasInteracted(alice, tokenA, 1));
        assertFalse(boostBurn.hasInteracted(bob, tokenA, 0));
    }

    function test_CurrentEpoch() public view {
        assertEq(boostBurn.currentEpoch(), 0);
    }

    function test_CurrentEpoch_AdvancesAfterDuration() public {
        vm.warp(epochZero + EPOCH_DURATION);
        assertEq(boostBurn.currentEpoch(), 1);
        vm.warp(epochZero + 3 * EPOCH_DURATION);
        assertEq(boostBurn.currentEpoch(), 3);
    }

    // ============ Zero Cost ============

    function test_ZeroCost_NoTransfer() public {
        vm.prank(owner);
        boostBurn.signalAction(ACTION_SET_BWLK_COST, keccak256(abi.encode(uint256(0))));
        vm.warp(block.timestamp + 7 days);
        boostBurn.executeSetBwlkCost(0);

        uint256 balBefore = bwlk.balanceOf(alice);
        vm.prank(alice);
        boostBurn.boost(tokenA);
        assertEq(bwlk.balanceOf(alice), balBefore, "zero cost should transfer no BWLK");
        assertEq(boostBurn.getScore(tokenA), 1, "zero-cost boost should still increment the score");
    }

    // ============ Admin: BWLK Cost ============

    function test_SignalExecuteBwlkCost() public {
        vm.prank(owner);
        boostBurn.signalAction(ACTION_SET_BWLK_COST, keccak256(abi.encode(0.5e18)));
        vm.warp(block.timestamp + 7 days);
        boostBurn.executeSetBwlkCost(0.5e18);
        assertEq(boostBurn.bwlkCost(), 0.5e18, "BWLK cost should update after the timelock");
    }

    function test_BwlkCostChanged_EmitsEvent() public {
        vm.prank(owner);
        boostBurn.signalAction(ACTION_SET_BWLK_COST, keccak256(abi.encode(0.5e18)));
        vm.warp(block.timestamp + 7 days);

        vm.expectEmit(true, true, true, true);
        emit BwlkCostChanged(0.1e18, 0.5e18);
        boostBurn.executeSetBwlkCost(0.5e18);
    }

    function test_RevertWhen_BwlkCostExceedsMax() public {
        vm.prank(owner);
        boostBurn.signalAction(ACTION_SET_BWLK_COST, keccak256(abi.encode(2e18)));
        vm.warp(block.timestamp + 7 days);

        vm.expectRevert(abi.encodeWithSelector(BoostBurn.BwlkCostOutOfRange.selector, 2e18));
        boostBurn.executeSetBwlkCost(2e18);
    }

    function test_RevertWhen_SignalBwlkCost_NotOwner() public {
        vm.expectRevert();
        vm.prank(alice);
        boostBurn.signalAction(ACTION_SET_BWLK_COST, keccak256(abi.encode(0.5e18)));
    }

    function test_CancelPendingAction() public {
        vm.prank(owner);
        boostBurn.signalAction(ACTION_SET_BWLK_COST, keccak256(abi.encode(0.5e18)));

        vm.prank(owner);
        boostBurn.cancelAction(ACTION_SET_BWLK_COST);

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        boostBurn.executeSetBwlkCost(0.5e18);
    }

    // ============ NFT Membership Discount ============

    function test_MemberBoost_PaysZeroByDefault() public {
        MockNFT nft = new MockNFT();
        BoostBurn bb = new BoostBurn(owner, address(bwlk), epochZero, EPOCH_DURATION, address(nft), 10_000);

        nft.mint(alice, 1);
        bwlk.mint(alice, 10e18);
        vm.prank(alice);
        bwlk.approve(address(bb), type(uint256).max);

        uint256 balBefore = bwlk.balanceOf(alice);
        vm.prank(alice);
        bb.boost(tokenA);
        assertEq(bwlk.balanceOf(alice), balBefore, "Member should pay zero with 100% discount");
    }

    function test_NonMemberBoost_PaysFullCost() public {
        MockNFT nft = new MockNFT();
        BoostBurn bb = new BoostBurn(owner, address(bwlk), epochZero, EPOCH_DURATION, address(nft), 10_000);

        bwlk.mint(alice, 10e18);
        vm.prank(alice);
        bwlk.approve(address(bb), type(uint256).max);

        uint256 balBefore = bwlk.balanceOf(alice);
        vm.prank(alice);
        bb.boost(tokenA);
        assertEq(bwlk.balanceOf(alice), balBefore - 0.1e18, "Non-member should pay full cost");
    }

    function test_MemberBoost_PartialDiscount() public {
        MockNFT nft = new MockNFT();
        BoostBurn bb = new BoostBurn(owner, address(bwlk), epochZero, EPOCH_DURATION, address(nft), 5000);

        nft.mint(alice, 1);
        bwlk.mint(alice, 10e18);
        vm.prank(alice);
        bwlk.approve(address(bb), type(uint256).max);

        uint256 balBefore = bwlk.balanceOf(alice);
        vm.prank(alice);
        bb.boost(tokenA);
        assertEq(bwlk.balanceOf(alice), balBefore - 0.05e18, "Member should pay 50% of cost");
    }

    function test_MemberDiscount_DisabledWhenNftZeroAddress() public {
        BoostBurn bb = new BoostBurn(owner, address(bwlk), epochZero, EPOCH_DURATION, address(0), 10_000);

        bwlk.mint(alice, 10e18);
        vm.prank(alice);
        bwlk.approve(address(bb), type(uint256).max);

        uint256 balBefore = bwlk.balanceOf(alice);
        vm.prank(alice);
        bb.boost(tokenA);
        assertEq(bwlk.balanceOf(alice), balBefore - 0.1e18, "Discount disabled when nft=address(0)");
    }

    function test_RevertWhen_Constructor_MemberDiscountAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(BoostBurn.MemberDiscountOutOfRange.selector, 10_001));
        new BoostBurn(owner, address(bwlk), epochZero, EPOCH_DURATION, address(0), 10_001);
    }

    function test_TimelockSetNftCollection() public {
        MockNFT nft = new MockNFT();
        bytes32 action = keccak256("SET_NFT_COLLECTION");

        vm.prank(owner);
        boostBurn.signalAction(action, keccak256(abi.encode(address(nft))));
        vm.warp(block.timestamp + 7 days);
        boostBurn.executeSetNftCollection(address(nft));
        assertEq(boostBurn.nftCollection(), address(nft));
    }

    function test_TimelockSetMemberBoostDiscount() public {
        bytes32 action = keccak256("SET_MEMBER_BOOST_DISCOUNT");

        vm.prank(owner);
        boostBurn.signalAction(action, keccak256(abi.encode(uint256(5000))));
        vm.warp(block.timestamp + 7 days);
        boostBurn.executeSetMemberBoostDiscount(5000);
        assertEq(boostBurn.memberBoostDiscountBps(), 5000);
    }

    function test_RevertWhen_MemberBoostDiscountAboveMax() public {
        bytes32 action = keccak256("SET_MEMBER_BOOST_DISCOUNT");

        vm.prank(owner);
        boostBurn.signalAction(action, keccak256(abi.encode(uint256(10_001))));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(abi.encodeWithSelector(BoostBurn.MemberDiscountOutOfRange.selector, 10_001));
        boostBurn.executeSetMemberBoostDiscount(10_001);
    }

    function test_RevertWhen_SignalNftCollection_NotOwner() public {
        bytes32 action = keccak256("SET_NFT_COLLECTION");
        vm.expectRevert();
        vm.prank(alice);
        boostBurn.signalAction(action, keccak256(abi.encode(address(1))));
    }

    function test_RevertingNft_RevertsOnInteraction() public {
        RevertingNFT badNft = new RevertingNFT();
        BoostBurn bb = new BoostBurn(owner, address(bwlk), epochZero, EPOCH_DURATION, address(badNft), 10_000);

        bwlk.mint(alice, 10e18);
        vm.prank(alice);
        bwlk.approve(address(bb), type(uint256).max);

        vm.expectRevert();
        vm.prank(alice);
        bb.boost(tokenA);
    }

    function test_ZeroBwlkCost_WithDiscount_NoExternalCall() public {
        MockNFT nft = new MockNFT();
        BoostBurn bb = new BoostBurn(owner, address(bwlk), epochZero, EPOCH_DURATION, address(nft), 10_000);

        vm.prank(owner);
        bb.signalAction(keccak256("SET_BWLK_COST"), keccak256(abi.encode(uint256(0))));
        vm.warp(block.timestamp + 7 days);
        bb.executeSetBwlkCost(0);

        nft.mint(alice, 1);
        uint256 balBefore = bwlk.balanceOf(alice);
        vm.prank(alice);
        bb.boost(tokenA);
        assertEq(bwlk.balanceOf(alice), balBefore, "Zero cost with discount should transfer nothing");
    }

    // ============ Fuzz ============

    function testFuzz_BoostDeboostScoreTracking(
        uint8 boostCount,
        uint8 deboostCount
    ) public {
        boostCount = uint8(bound(boostCount, 0, 10));
        deboostCount = uint8(bound(deboostCount, 0, 10));

        for (uint8 i = 0; i < boostCount;) {
            address user = makeAddr(string(abi.encode("booster", i)));
            bwlk.mint(user, 1e18);
            vm.prank(user);
            bwlk.approve(address(boostBurn), type(uint256).max);
            vm.prank(user);
            boostBurn.boost(tokenA);
            unchecked {
                ++i;
            }
        }

        for (uint8 i = 0; i < deboostCount;) {
            address user = makeAddr(string(abi.encode("debooster", i)));
            bwlk.mint(user, 1e18);
            vm.prank(user);
            bwlk.approve(address(boostBurn), type(uint256).max);
            vm.prank(user);
            boostBurn.deboost(tokenA);
            unchecked {
                ++i;
            }
        }

        assertEq(boostBurn.getScore(tokenA), int256(uint256(boostCount)) - int256(uint256(deboostCount)));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ParticipationDistributor} from "src/governance/ParticipationDistributor.sol";
import {IGovernanceVoter} from "src/interfaces/IGovernanceVoter.sol";

contract MockBMXToken {
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

contract MockGovernanceVoter {
    mapping(uint256 => IGovernanceVoter.EpochInfo) private _epochInfos;
    mapping(uint256 => mapping(address => IGovernanceVoter.UserVote)) private _userVotes;

    function setEpochInfo(uint256 epoch, uint256 totalVoteWeight) external {
        _epochInfos[epoch].totalVoteWeight = totalVoteWeight;
    }

    function setUserVote(uint256 epoch, address user, uint8 option, uint256 weight) external {
        _userVotes[epoch][user] = IGovernanceVoter.UserVote({weight: uint248(weight), option: option});
    }

    function getEpochInfo(
        uint256 epoch
    ) external view returns (IGovernanceVoter.EpochInfo memory) {
        return _epochInfos[epoch];
    }

    function getUserVote(uint256 epoch, address user) external view returns (IGovernanceVoter.UserVote memory) {
        return _userVotes[epoch][user];
    }
}

contract ParticipationDistributorTest is Test {
    ParticipationDistributor public distributor;
    MockBMXToken public bmx;
    MockGovernanceVoter public mockVoter;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    event StreamCreated(uint256 indexed epoch, uint256 totalBmx, uint256 totalWeight);
    event Claimed(uint256 indexed epoch, address indexed user, uint256 amount);

    function setUp() public {
        bmx = new MockBMXToken();
        mockVoter = new MockGovernanceVoter();
        distributor = new ParticipationDistributor(address(bmx), address(mockVoter));

        mockVoter.setEpochInfo(0, 1000e18);
        mockVoter.setUserVote(0, alice, 1, 700e18);
        mockVoter.setUserVote(0, bob, 2, 300e18);
    }

    function _createStream(uint256 epoch, uint256 amount) internal {
        bmx.mint(address(mockVoter), amount);
        vm.startPrank(address(mockVoter));
        bmx.approve(address(distributor), amount);
        distributor.createStream(epoch, amount);
        vm.stopPrank();
    }

    // ============ Stream Creation ============

    function test_CreateStream_HappyPath() public {
        uint256 amount = 100e18;
        bmx.mint(address(mockVoter), amount);
        vm.startPrank(address(mockVoter));
        bmx.approve(address(distributor), amount);

        vm.expectEmit(true, true, true, true);
        emit StreamCreated(1, amount, 1000e18);
        distributor.createStream(1, amount);
        vm.stopPrank();

        (uint256 totalBmx, uint256 totalWeight, uint256 startTime) = distributor.streams(1);
        assertEq(totalBmx, amount);
        assertEq(totalWeight, 1000e18);
        assertEq(startTime, block.timestamp);
    }

    function test_RevertWhen_CreateStream_NotVoter() public {
        vm.expectRevert(ParticipationDistributor.NotGovernanceVoter.selector);
        vm.prank(alice);
        distributor.createStream(1, 100e18);
    }

    function test_RevertWhen_CreateStream_AlreadyExists() public {
        _createStream(1, 100e18);

        bmx.mint(address(mockVoter), 100e18);
        vm.startPrank(address(mockVoter));
        bmx.approve(address(distributor), 100e18);
        vm.expectRevert(ParticipationDistributor.StreamAlreadyExists.selector);
        distributor.createStream(1, 100e18);
        vm.stopPrank();
    }

    // ============ Claiming ============

    function test_Claim_LinearVesting() public {
        _createStream(1, 100e18);

        vm.warp(block.timestamp + 3.5 days);
        (uint256 totalAllocation, uint256 claimableAmt) = distributor.claimable(1, alice);
        uint256 expectedShare = 100e18 * 700e18 / 1000e18;
        uint256 expected = expectedShare * 3.5 days / 7 days;
        assertEq(totalAllocation, expectedShare);
        assertApproxEqAbs(claimableAmt, expected, 1);

        vm.prank(alice);
        distributor.claim(1);
        assertApproxEqAbs(bmx.balanceOf(alice), expected, 1);
    }

    function test_Claim_FullAfterStreamDuration() public {
        _createStream(1, 100e18);

        vm.warp(block.timestamp + 7 days);

        uint256 aliceShare = 100e18 * 700e18 / 1000e18;
        uint256 bobShare = 100e18 * 300e18 / 1000e18;

        vm.prank(alice);
        distributor.claim(1);
        vm.prank(bob);
        distributor.claim(1);

        assertEq(bmx.balanceOf(alice), aliceShare);
        assertEq(bmx.balanceOf(bob), bobShare);
    }

    function test_Claim_MultipleClaims() public {
        _createStream(1, 100e18);
        uint256 aliceShare = 100e18 * 700e18 / 1000e18;

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        distributor.claim(1);
        uint256 first = bmx.balanceOf(alice);

        vm.warp(block.timestamp + 6 days);
        vm.prank(alice);
        distributor.claim(1);

        assertEq(bmx.balanceOf(alice), aliceShare);
        assertGt(bmx.balanceOf(alice), first);
    }

    function test_RevertWhen_Claim_NotEligible() public {
        _createStream(1, 100e18);
        address nobody = makeAddr("nobody");

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(ParticipationDistributor.NothingToClaim.selector);
        vm.prank(nobody);
        distributor.claim(1);
    }

    function test_RevertWhen_Claim_NothingToClaim() public {
        _createStream(1, 100e18);

        vm.expectRevert(ParticipationDistributor.NothingToClaim.selector);
        vm.prank(alice);
        distributor.claim(1);
    }

    function test_Claimable_ZeroForNonVoter() public {
        _createStream(1, 100e18);
        vm.warp(block.timestamp + 7 days);
        (uint256 alloc, uint256 claimableAmt) = distributor.claimable(1, makeAddr("nobody"));
        assertEq(alloc, 0);
        assertEq(claimableAmt, 0);
    }

    function test_Claimable_ZeroAtStartTime() public {
        _createStream(1, 100e18);
        (uint256 alloc, uint256 claimableAmt) = distributor.claimable(1, alice);
        assertEq(alloc, 70e18);
        assertEq(claimableAmt, 0);
    }

    function test_Claimable_ZeroForNonexistentStream() public {
        (uint256 alloc, uint256 claimableAmt) = distributor.claimable(99, alice);
        assertEq(alloc, 0);
        assertEq(claimableAmt, 0);
    }

    function test_CreateStream_WithZeroWeight() public {
        mockVoter.setEpochInfo(0, 0);

        bmx.mint(address(mockVoter), 100e18);
        vm.startPrank(address(mockVoter));
        bmx.approve(address(distributor), 100e18);
        distributor.createStream(1, 100e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        (, uint256 claimableAmt) = distributor.claimable(1, alice);
        assertEq(claimableAmt, 0);
    }

    function test_Claim_PartialVesting_AtOneDay() public {
        _createStream(1, 100e18);
        uint256 aliceShare = 100e18 * 700e18 / 1000e18;

        vm.warp(block.timestamp + 1 days);
        uint256 expected = aliceShare * 1 days / 7 days;
        (, uint256 claimableAmt) = distributor.claimable(1, alice);
        assertApproxEqAbs(claimableAmt, expected, 1);
    }

    function test_RevertWhen_Claim_AfterFullyClaimed() public {
        _createStream(1, 100e18);
        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        distributor.claim(1);

        vm.expectRevert(ParticipationDistributor.NothingToClaim.selector);
        vm.prank(alice);
        distributor.claim(1);
    }

    // ============ claimAll ============

    function test_ClaimAll_MultipleEpochs() public {
        _createStream(1, 100e18);

        mockVoter.setEpochInfo(1, 1000e18);
        mockVoter.setUserVote(1, alice, 1, 700e18);
        _createStream(2, 200e18);

        vm.warp(block.timestamp + 7 days);

        uint256 epoch1Share = 100e18 * 700e18 / 1000e18;
        uint256 epoch2Share = 200e18 * 700e18 / 1000e18;

        uint256[] memory epochs = new uint256[](2);
        epochs[0] = 1;
        epochs[1] = 2;

        vm.expectEmit(true, true, true, true);
        emit Claimed(1, alice, epoch1Share);
        vm.expectEmit(true, true, true, true);
        emit Claimed(2, alice, epoch2Share);

        vm.prank(alice);
        distributor.claimAll(epochs);

        assertEq(bmx.balanceOf(alice), epoch1Share + epoch2Share);
    }

    function test_ClaimAll_SkipsZeroClaimableEpochs() public {
        _createStream(1, 100e18);

        mockVoter.setEpochInfo(1, 1000e18);
        mockVoter.setUserVote(1, alice, 1, 700e18);
        _createStream(2, 200e18);

        vm.warp(block.timestamp + 7 days);

        vm.prank(alice);
        distributor.claim(1);
        uint256 balAfterFirst = bmx.balanceOf(alice);

        uint256[] memory epochs = new uint256[](2);
        epochs[0] = 1;
        epochs[1] = 2;

        vm.prank(alice);
        distributor.claimAll(epochs);

        uint256 epoch2Share = 200e18 * 700e18 / 1000e18;
        assertEq(bmx.balanceOf(alice), balAfterFirst + epoch2Share);
    }

    function test_ClaimAll_PartialVesting() public {
        _createStream(1, 100e18);

        mockVoter.setEpochInfo(1, 1000e18);
        mockVoter.setUserVote(1, alice, 1, 700e18);
        _createStream(2, 200e18);

        vm.warp(block.timestamp + 3.5 days);

        uint256 epoch1Share = 100e18 * 700e18 / 1000e18;
        uint256 epoch2Share = 200e18 * 700e18 / 1000e18;
        uint256 expectedTotal = (epoch1Share + epoch2Share) / 2;

        uint256[] memory epochs = new uint256[](2);
        epochs[0] = 1;
        epochs[1] = 2;

        vm.prank(alice);
        distributor.claimAll(epochs);

        assertApproxEqAbs(bmx.balanceOf(alice), expectedTotal, 1);
    }

    function test_RevertWhen_ClaimAll_NothingToClaim() public {
        _createStream(1, 100e18);
        address nobody = makeAddr("nobody");

        vm.warp(block.timestamp + 7 days);

        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 1;

        vm.expectRevert(ParticipationDistributor.NothingToClaim.selector);
        vm.prank(nobody);
        distributor.claimAll(epochs);
    }

    function test_ClaimAll_EmptyArray() public {
        uint256[] memory epochs = new uint256[](0);

        vm.expectRevert(ParticipationDistributor.NothingToClaim.selector);
        vm.prank(alice);
        distributor.claimAll(epochs);
    }

    function test_ClaimAll_SingleEpoch() public {
        _createStream(1, 100e18);
        vm.warp(block.timestamp + 7 days);

        uint256 aliceShare = 100e18 * 700e18 / 1000e18;

        uint256[] memory epochs = new uint256[](1);
        epochs[0] = 1;

        vm.prank(alice);
        distributor.claimAll(epochs);

        assertEq(bmx.balanceOf(alice), aliceShare);
        assertEq(distributor.claimed(1, alice), aliceShare);
    }

    // ============ Allocation via claimable ============

    function test_Claimable_ReturnsAllocation_FullStream() public {
        _createStream(1, 100e18);
        vm.warp(block.timestamp + 7 days);

        (uint256 alloc, uint256 claimableAmt) = distributor.claimable(1, alice);
        assertEq(alloc, 70e18);
        assertEq(claimableAmt, 70e18);
    }

    function test_Claimable_AllocationUnchanged_AfterPartialClaim() public {
        uint256 start = block.timestamp;
        _createStream(1, 100e18);
        vm.warp(start + 3.5 days);

        vm.prank(alice);
        distributor.claim(1);

        (uint256 alloc, uint256 claimableAmt) = distributor.claimable(1, alice);
        assertEq(alloc, 70e18);
        assertEq(claimableAmt, 0);

        vm.warp(start + 7 days);
        (alloc, claimableAmt) = distributor.claimable(1, alice);
        assertEq(alloc, 70e18);
        assertEq(claimableAmt, 70e18 - distributor.claimed(1, alice));
    }

    function test_Claimable_ZeroWhenRoundedAllocationIsZero() public {
        // tiny stream + tiny weight share => allocation rounds down to zero
        mockVoter.setEpochInfo(5, 1000);
        mockVoter.setUserVote(5, alice, 1, 1);

        bmx.mint(address(mockVoter), 1);
        vm.startPrank(address(mockVoter));
        bmx.approve(address(distributor), 1);
        distributor.createStream(6, 1);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        (uint256 alloc, uint256 claimableAmt) = distributor.claimable(6, alice);
        assertEq(alloc, 0);
        assertEq(claimableAmt, 0);
    }
}

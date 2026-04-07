// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {LPLocker} from "src/governance/LPLocker.sol";

/// @dev Mock PositionManager that accepts modifyLiquidities calls (replaces MockUniversalRouter)
contract MockPositionManager {
    function modifyLiquidities(bytes calldata, uint256) external payable {}

    // ERC721 support — needed for safeTransferFrom tests
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "Not owner");
        ownerOf[tokenId] = to;
        (bool success,) = to.call(
            abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", msg.sender, from, tokenId, "")
        );
        require(success, "Transfer rejected");
    }
}

/// @dev Mock GovernanceVoter that returns a treasury address
contract MockGovernanceVoterForLocker {
    address public treasury;

    constructor(address _treasury) {
        treasury = _treasury;
    }

    function setTreasury(address _treasury) external {
        treasury = _treasury;
    }
}

contract LPLockerTest is Test {
    LPLocker public locker;
    MockPositionManager public positionManager;
    MockGovernanceVoterForLocker public mockGovernanceVoter;

    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public currency0 = makeAddr("currency0");
    address public currency1 = makeAddr("currency1");

    event LPLocked(uint256 indexed tokenId);
    event FeesClaimed(uint256 indexed tokenId);

    function setUp() public {
        positionManager = new MockPositionManager();
        mockGovernanceVoter = new MockGovernanceVoterForLocker(treasury);
        locker = new LPLocker(
            address(positionManager),
            address(mockGovernanceVoter),
            currency0,
            currency1
        );
    }

    function test_OnERC721Received_FromPositionManager_AutoLocks() public {
        positionManager.mint(address(mockGovernanceVoter), 1);

        vm.expectEmit(true, true, true, true);
        emit LPLocked(1);

        vm.prank(address(mockGovernanceVoter));
        positionManager.safeTransferFrom(address(mockGovernanceVoter), address(locker), 1);

        assertTrue(locker.lockedPositions(1));
    }

    function test_OnERC721Received_AcceptsAnySenderWhenPositionManagerCalls() public {
        positionManager.mint(alice, 2);

        vm.expectEmit(true, true, true, true);
        emit LPLocked(2);

        vm.prank(alice);
        positionManager.safeTransferFrom(alice, address(locker), 2);

        assertTrue(locker.lockedPositions(2));
    }

    function test_RevertWhen_OnERC721Received_DirectCallNotPositionManager() public {
        vm.expectRevert(LPLocker.NotAuthorized.selector);
        vm.prank(alice);
        locker.onERC721Received(address(0), address(0), 3, "");
    }

    // ============ lockPosition ============

    function test_LockPosition_HappyPath() public {
        vm.expectEmit(true, true, true, true);
        emit LPLocked(42);

        vm.prank(address(mockGovernanceVoter));
        locker.lockPosition(42);

        assertTrue(locker.lockedPositions(42));
    }

    function test_RevertWhen_LockPosition_NotGovernanceVoter() public {
        vm.expectRevert(LPLocker.NotAuthorized.selector);
        vm.prank(alice);
        locker.lockPosition(42);
    }

    function test_RevertWhen_LockPosition_AlreadyLocked() public {
        vm.prank(address(mockGovernanceVoter));
        locker.lockPosition(42);

        vm.expectRevert(LPLocker.AlreadyLocked.selector);
        vm.prank(address(mockGovernanceVoter));
        locker.lockPosition(42);
    }

    function test_ClaimFees_EmitsEvent() public {
        positionManager.mint(address(mockGovernanceVoter), 1);
        vm.prank(address(mockGovernanceVoter));
        positionManager.safeTransferFrom(address(mockGovernanceVoter), address(locker), 1);

        vm.expectEmit(true, true, true, true);
        emit FeesClaimed(1);
        locker.claimFees(1);
    }

    function test_RevertWhen_ClaimFees_NotLocked() public {
        vm.expectRevert(LPLocker.PositionNotLocked.selector);
        locker.claimFees(999);
    }

    // ============ Dynamic Treasury ============

    function test_ClaimFees_UsesDynamicTreasury() public {
        vm.prank(address(mockGovernanceVoter));
        locker.lockPosition(1);

        // Change treasury
        address newTreasury = makeAddr("newTreasury");
        mockGovernanceVoter.setTreasury(newTreasury);

        // Should not revert — reads dynamic treasury from GovernanceVoter
        locker.claimFees(1);
    }

    // ============ getLockedPositions ============

    function test_GetLockedPositions_Empty() public view {
        uint256[] memory ids = locker.getLockedPositions();
        assertEq(ids.length, 0);
    }

    function test_GetLockedPositions_TracksLockPosition() public {
        vm.startPrank(address(mockGovernanceVoter));
        locker.lockPosition(10);
        locker.lockPosition(20);
        locker.lockPosition(30);
        vm.stopPrank();

        uint256[] memory ids = locker.getLockedPositions();
        assertEq(ids.length, 3);
        assertEq(ids[0], 10);
        assertEq(ids[1], 20);
        assertEq(ids[2], 30);
    }

    function test_GetLockedPositions_TracksOnERC721Received() public {
        positionManager.mint(alice, 5);
        positionManager.mint(alice, 6);

        vm.startPrank(alice);
        positionManager.safeTransferFrom(alice, address(locker), 5);
        positionManager.safeTransferFrom(alice, address(locker), 6);
        vm.stopPrank();

        uint256[] memory ids = locker.getLockedPositions();
        assertEq(ids.length, 2);
        assertEq(ids[0], 5);
        assertEq(ids[1], 6);
    }

    function test_GetLockedPositions_TracksBothPaths() public {
        vm.prank(address(mockGovernanceVoter));
        locker.lockPosition(100);

        positionManager.mint(alice, 200);
        vm.prank(alice);
        positionManager.safeTransferFrom(alice, address(locker), 200);

        uint256[] memory ids = locker.getLockedPositions();
        assertEq(ids.length, 2);
        assertEq(ids[0], 100);
        assertEq(ids[1], 200);
    }

    // ============ claimAllFees ============

    function test_ClaimAllFees_MultiplePositions() public {
        vm.startPrank(address(mockGovernanceVoter));
        locker.lockPosition(1);
        locker.lockPosition(2);
        locker.lockPosition(3);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true);
        emit FeesClaimed(1);
        vm.expectEmit(true, true, true, true);
        emit FeesClaimed(2);
        vm.expectEmit(true, true, true, true);
        emit FeesClaimed(3);

        locker.claimAllFees();
    }

    function test_ClaimAllFees_SinglePosition() public {
        vm.prank(address(mockGovernanceVoter));
        locker.lockPosition(42);

        vm.expectEmit(true, true, true, true);
        emit FeesClaimed(42);

        locker.claimAllFees();
    }

    function test_RevertWhen_ClaimAllFees_NoPositions() public {
        vm.expectRevert(LPLocker.NoPositions.selector);
        locker.claimAllFees();
    }

    function test_RevertWhen_OnERC721Received_AlreadyLocked() public {
        positionManager.mint(alice, 77);

        vm.prank(alice);
        positionManager.safeTransferFrom(alice, address(locker), 77);

        vm.expectRevert(LPLocker.AlreadyLocked.selector);
        vm.prank(address(positionManager));
        locker.onERC721Received(address(0), alice, 77, "");
    }
}

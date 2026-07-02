// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {LPLocker} from "src/governance/LPLocker.sol";
import {IV4PositionManager} from "src/interfaces/IV4PositionManager.sol";

/// @dev Mock PositionManager that accepts modifyLiquidities calls (replaces MockUniversalRouter)
contract MockPositionManager {
    function modifyLiquidities(bytes calldata, uint256) external payable {}

    // ERC721 support — needed for safeTransferFrom tests
    mapping(uint256 => address) public ownerOf;

    // Pool key returned for registered positions (defaults to the locker's currencies in setUp).
    address public poolC0;
    address public poolC1;

    function setPool(address c0, address c1) external {
        poolC0 = c0;
        poolC1 = c1;
    }

    function getPoolAndPositionInfo(
        uint256
    ) external view returns (IV4PositionManager.PoolKey memory, uint256) {
        return (IV4PositionManager.PoolKey(poolC0, poolC1, 0, 0, address(0)), 0);
    }

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "Not owner");
        ownerOf[tokenId] = to;
        // Mirrors the OZ ERC721 contract: invoke onERC721Received if `to` is a contract; revert
        // if the receiver does not return the magic selector. After LPLocker no longer
        // implements the hook, so calls into it from this path now revert.
        if (to.code.length > 0) {
            (bool success, bytes memory ret) = to.call(
                abi.encodeWithSignature(
                    "onERC721Received(address,address,uint256,bytes)", msg.sender, from, tokenId, ""
                )
            );
            require(
                success && ret.length >= 4 && bytes4(ret) == bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")),
                "Transfer rejected"
            );
        }
    }

    /// @notice Non-safe ERC-721 transfer. Does NOT invoke `onERC721Received` on the receiver.
    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "Not owner");
        ownerOf[tokenId] = to;
    }
}

/// @dev Mock GovernanceVoter: treasury for claims + the pool params registerPosition pins against.
///      Defaults (0, 0, address(0)) match MockPositionManager's fixed key.
contract MockGovernanceVoterForLocker {
    address public treasury;
    uint24 public POOL_FEE;
    int24 public POOL_TICK_SPACING;
    address public POOL_HOOKS;
    bool public poolHooksSet = true;

    constructor(address _treasury) {
        treasury = _treasury;
    }

    function setTreasury(address _treasury) external {
        treasury = _treasury;
    }

    function setPoolParams(uint24 fee, int24 tickSpacing, address hooks) external {
        POOL_FEE = fee;
        POOL_TICK_SPACING = tickSpacing;
        POOL_HOOKS = hooks;
    }

    function setPoolHooksSet(bool v) external {
        poolHooksSet = v;
    }
}

contract LPLockerTest is Test {
    LPLocker public locker;
    MockPositionManager public positionManager;
    MockGovernanceVoterForLocker public mockGovernanceVoter;

    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public registrar = makeAddr("registrar");
    address public currency0 = makeAddr("currency0");
    address public currency1 = makeAddr("currency1");

    event LPLocked(uint256 indexed tokenId);
    event FeesClaimed(uint256 indexed tokenId);
    event RegistrarRenounced(address indexed registrar);

    function setUp() public {
        positionManager = new MockPositionManager();
        mockGovernanceVoter = new MockGovernanceVoterForLocker(treasury);
        locker = new LPLocker(
            address(positionManager),
            address(mockGovernanceVoter),
            currency0,
            currency1,
            registrar
        );
        // Default: positions report the locker's pool so registerPosition's pool-key check passes.
        positionManager.setPool(currency0, currency1);
    }

    // ============ NFT injection — onERC721Received removed ============

    /// @notice safeTransferFrom from any external account (PositionManager included as the
    ///         sender) must REVERT at the receiver: LPLocker no longer implements
    ///         `onERC721Received`, so the receiver-hook check in OZ-style ERC721 transfers
    ///         fails. This blocks arbitrary NFT injection that previously inflated
    ///         `lockedTokenIds` and `claimAllFees` iteration.
    function test_RevertWhen_DirectNftTransfer_FromExternalAccount() public {
        positionManager.mint(alice, 99);
        vm.expectRevert(bytes("Transfer rejected"));
        vm.prank(alice);
        positionManager.safeTransferFrom(alice, address(locker), 99);
    }

    /// @notice Acknowledged residual: a plain (non-safe) `transferFrom` skips the receiver
    ///         hook and the NFT ends up owned by the locker. That id is NOT registered in
    ///         `lockedTokenIds`, so `claimAllFees` ignores it and accounting stays correct.
    ///         The stranded NFT is permanently inaccessible — no rescue path exists, the
    ///         prior owner voluntarily transferred it. This is a deliberate trade-off: the
    ///         alternative (an allowlist on receipt) adds surface area for marginal gain.
    function test_PlainTransferFrom_StrandsNftButDoesNotBreakClaim() public {
        positionManager.mint(alice, 99);
        // First, legitimately lock a position so claimAllFees has something to iterate.
        vm.prank(address(mockGovernanceVoter));
        locker.lockPosition(1);
        uint256 lengthBefore = locker.getLockedPositions().length;

        // Attacker strands an NFT via plain transferFrom — succeeds (no hook called).
        vm.prank(alice);
        positionManager.transferFrom(alice, address(locker), 99);
        assertEq(positionManager.ownerOf(99), address(locker), "NFT now owned by locker");

        // Critical assertions: locker accounting is unchanged.
        assertFalse(locker.lockedPositions(99), "stranded id NOT marked locked");
        assertEq(locker.getLockedPositions().length, lengthBefore, "stranded id NOT pushed");

        // claimAllFees still functions on the legitimately locked positions and is not influenced
        // by the stranded id.
        vm.expectEmit(true, true, true, true);
        emit FeesClaimed(1);
        locker.claimAllFees(block.timestamp);
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
        // Positions are locked exclusively via lockPosition from the GovernanceVoter.
        vm.prank(address(mockGovernanceVoter));
        locker.lockPosition(1);

        vm.expectEmit(true, true, true, true);
        emit FeesClaimed(1);
        locker.claimFees(1, block.timestamp);
    }

    function test_RevertWhen_ClaimFees_NotLocked() public {
        vm.expectRevert(LPLocker.PositionNotLocked.selector);
        locker.claimFees(999, block.timestamp);
    }

    // ============ Dynamic Treasury ============

    function test_ClaimFees_UsesDynamicTreasury() public {
        vm.prank(address(mockGovernanceVoter));
        locker.lockPosition(1);

        // Change treasury
        address newTreasury = makeAddr("newTreasury");
        mockGovernanceVoter.setTreasury(newTreasury);

        // Should not revert — reads dynamic treasury from GovernanceVoter
        locker.claimFees(1, block.timestamp);
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

    /// @notice lockPosition is the sole registration path. Multiple locks accumulate
    ///         into `lockedTokenIds` in call order.
    function test_GetLockedPositions_TracksLockPosition_Multiple() public {
        vm.startPrank(address(mockGovernanceVoter));
        locker.lockPosition(5);
        locker.lockPosition(6);
        vm.stopPrank();

        uint256[] memory ids = locker.getLockedPositions();
        assertEq(ids.length, 2);
        assertEq(ids[0], 5);
        assertEq(ids[1], 6);
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

        locker.claimAllFees(block.timestamp);
    }

    function test_ClaimAllFees_SinglePosition() public {
        vm.prank(address(mockGovernanceVoter));
        locker.lockPosition(42);

        vm.expectEmit(true, true, true, true);
        emit FeesClaimed(42);

        locker.claimAllFees(block.timestamp);
    }

    function test_RevertWhen_ClaimAllFees_NoPositions() public {
        vm.expectRevert(LPLocker.NoPositions.selector);
        locker.claimAllFees(block.timestamp);
    }

    /// @notice Only the GovernanceVoter can lock, so a double-lock requires two calls
    ///         from the voter for the same id.
    function test_RevertWhen_LockPosition_DoubleLock() public {
        vm.prank(address(mockGovernanceVoter));
        locker.lockPosition(77);

        vm.expectRevert(LPLocker.AlreadyLocked.selector);
        vm.prank(address(mockGovernanceVoter));
        locker.lockPosition(77);
    }

    // ============ registerPosition (CCA path) ============

    function test_Registrar_InitialValue() public view {
        assertEq(locker.registrar(), registrar);
    }

    function test_RegisterPosition_HappyPath() public {
        positionManager.mint(address(locker), 123);

        vm.expectEmit(true, true, true, true);
        emit LPLocked(123);
        vm.prank(registrar);
        locker.registerPosition(123);

        assertTrue(locker.lockedPositions(123));
        uint256[] memory ids = locker.getLockedPositions();
        assertEq(ids.length, 1);
        assertEq(ids[0], 123);
    }

    function test_RegisterPosition_ThenFeesClaimable() public {
        positionManager.mint(address(locker), 123);
        vm.prank(registrar);
        locker.registerPosition(123);

        vm.expectEmit(true, true, true, true);
        emit FeesClaimed(123);
        locker.claimFees(123, block.timestamp);
    }

    function test_RevertWhen_RegisterPosition_NotRegistrar() public {
        positionManager.mint(address(locker), 123);
        vm.expectRevert(LPLocker.NotRegistrar.selector);
        vm.prank(alice);
        locker.registerPosition(123);
    }

    function test_RevertWhen_RegisterPosition_NotOwned() public {
        // Position exists but is owned by alice, not the locker.
        positionManager.mint(alice, 123);
        vm.expectRevert(LPLocker.NotPositionOwner.selector);
        vm.prank(registrar);
        locker.registerPosition(123);
    }

    function test_RevertWhen_RegisterPosition_PoolMismatch() public {
        positionManager.mint(address(locker), 123);
        positionManager.setPool(makeAddr("otherC0"), makeAddr("otherC1"));
        vm.expectRevert(LPLocker.PoolKeyMismatch.selector);
        vm.prank(registrar);
        locker.registerPosition(123);
    }

    function test_RevertWhen_RegisterPosition_FeeTierMismatch() public {
        // Same currency pair, but the position's pool uses a different fee tier than the voter's.
        positionManager.mint(address(locker), 123);
        mockGovernanceVoter.setPoolParams(10_000, 0, address(0));
        vm.expectRevert(LPLocker.PoolKeyMismatch.selector);
        vm.prank(registrar);
        locker.registerPosition(123);
    }

    function test_RevertWhen_RegisterPosition_TickSpacingMismatch() public {
        positionManager.mint(address(locker), 123);
        mockGovernanceVoter.setPoolParams(0, 200, address(0));
        vm.expectRevert(LPLocker.PoolKeyMismatch.selector);
        vm.prank(registrar);
        locker.registerPosition(123);
    }

    function test_RevertWhen_RegisterPosition_HooksMismatch() public {
        // Same pair + fee + tick, foreign hook: the hostile-hook pool that would brick claimAllFees.
        positionManager.mint(address(locker), 123);
        mockGovernanceVoter.setPoolParams(0, 0, makeAddr("foreignHook"));
        vm.expectRevert(LPLocker.PoolKeyMismatch.selector);
        vm.prank(registrar);
        locker.registerPosition(123);
    }

    function test_RevertWhen_RegisterPosition_PoolHooksNotCommitted() public {
        // Before setPoolHooks commits the voter's hook, the hook pin is vacuous - registration waits.
        positionManager.mint(address(locker), 123);
        mockGovernanceVoter.setPoolHooksSet(false);
        vm.expectRevert(LPLocker.PoolHooksNotSet.selector);
        vm.prank(registrar);
        locker.registerPosition(123);
    }

    function test_RevertWhen_RegisterPosition_AlreadyLocked() public {
        positionManager.mint(address(locker), 123);
        vm.prank(registrar);
        locker.registerPosition(123);

        vm.expectRevert(LPLocker.AlreadyLocked.selector);
        vm.prank(registrar);
        locker.registerPosition(123);
    }

    /// @notice Junk NFTs plain-transferred in cannot be registered by a non-registrar, so an attacker
    ///         cannot bloat `claimAllFees`. (Even the registrar would only register the real position.)
    function test_RegisterPosition_JunkNotRegisterableByAttacker() public {
        positionManager.mint(alice, 99);
        vm.prank(alice);
        positionManager.transferFrom(alice, address(locker), 99); // strands NFT (locker owns it)

        // Attacker is not the registrar -> cannot register the stranded id.
        vm.expectRevert(LPLocker.NotRegistrar.selector);
        vm.prank(alice);
        locker.registerPosition(99);

        assertFalse(locker.lockedPositions(99));
    }

    // ============ renounceRegistrar ============

    function test_RenounceRegistrar() public {
        vm.expectEmit(true, true, true, true);
        emit RegistrarRenounced(registrar);
        vm.prank(registrar);
        locker.renounceRegistrar();

        assertEq(locker.registrar(), address(0));

        // After renounce, registration is permanently disabled.
        positionManager.mint(address(locker), 123);
        vm.expectRevert(LPLocker.NotRegistrar.selector);
        vm.prank(registrar);
        locker.registerPosition(123);
    }

    function test_RevertWhen_RenounceRegistrar_NotRegistrar() public {
        vm.expectRevert(LPLocker.NotRegistrar.selector);
        vm.prank(alice);
        locker.renounceRegistrar();
    }

    // ============ receive (native ETH from PositionManager during claimFees) ============

    function test_Receive_FromPositionManager() public {
        vm.deal(address(positionManager), 1 ether);
        vm.prank(address(positionManager));
        (bool ok,) = address(locker).call{value: 1 ether}("");
        assertTrue(ok, "PositionManager ETH accepted");
        assertEq(address(locker).balance, 1 ether);
    }

    function test_RevertWhen_Receive_NotPositionManager() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(locker).call{value: 1 ether}("");
        assertFalse(ok, "non-PositionManager ETH rejected");
    }
}

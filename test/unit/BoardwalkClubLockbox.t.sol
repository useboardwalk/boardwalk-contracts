// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {BoardwalkClubLockbox} from "src/nft/BoardwalkClubLockbox.sol";
import {BoardwalkClubBridgeBase} from "src/nft/BoardwalkClubBridgeBase.sol";
import {Timelocked} from "src/base/Timelocked.sol";

/// @dev Minimal stand-in for the Boardwalk Club SeaDrop collection (ids minted on demand).
contract MockBBC is ERC721 {
    constructor() ERC721("Boardwalk Beach Club", "BBC") {}

    function mint(
        address to,
        uint256 tokenId
    ) external {
        _mint(to, tokenId);
    }
}

/// @dev Records outbound CCIP messages and replays inbound ones as the router. `ccipSend`
///      requires `msg.value` to equal the quoted fee, so forwarding `msg.value` instead of
///      the fee fails here.
contract MockCCIPRouter {
    error FeeMismatch();

    uint256 public fee = 0.01 ether;
    uint256 public sendCount;
    uint64 public lastSelector;
    bytes public lastReceiver;
    bytes public lastData;
    bytes public lastExtraArgs;
    address public lastFeeToken;

    function setFee(
        uint256 newFee
    ) external {
        fee = newFee;
    }

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    ) external view returns (uint256) {
        return fee;
    }

    function ccipSend(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage calldata message
    ) external payable returns (bytes32) {
        if (msg.value != fee) revert FeeMismatch();
        lastSelector = destinationChainSelector;
        lastReceiver = message.receiver;
        lastData = message.data;
        lastExtraArgs = message.extraArgs;
        lastFeeToken = message.feeToken;
        unchecked {
            ++sendCount;
        }
        return keccak256(abi.encode(sendCount, destinationChainSelector, message.data));
    }

    /// @dev Deliver an inbound message to `target` with this mock as `msg.sender` (the router).
    function deliver(
        address target,
        bytes32 messageId,
        uint64 sourceChainSelector,
        address sender,
        bytes memory data
    ) external {
        IAny2EVMMessageReceiver(target)
            .ccipReceive(
                Client.Any2EVMMessage({
                    messageId: messageId,
                    sourceChainSelector: sourceChainSelector,
                    sender: abi.encode(sender),
                    data: data,
                    destTokenAmounts: new Client.EVMTokenAmount[](0)
                })
            );
    }
}

/// @dev Caller that cannot receive ETH; exercises the RefundFailed branch.
contract EthRejector {
    function approveAll(
        MockBBC nft,
        address operator
    ) external {
        nft.setApprovalForAll(operator, true);
    }

    function doBridge(
        BoardwalkClubLockbox lockbox,
        uint64 destinationChainSelector,
        uint256 tokenId,
        address recipient
    ) external payable {
        lockbox.bridge{value: msg.value}(destinationChainSelector, tokenId, recipient);
    }
}

/// @title BoardwalkClubLockboxTest
/// @notice Unit and fuzz tests for the Base-side lock/release half of the Boardwalk Club bridge.
contract BoardwalkClubLockboxTest is Test {
    // ============ Constants ============

    uint64 internal constant SEL_SPOKE = 1111;
    uint64 internal constant SEL_OTHER = 2222;
    uint64 internal constant SEL_UNKNOWN = 9999;
    uint256 internal constant TOKEN_ID = 7;
    uint256 internal constant DEST_GAS_LIMIT = 200_000;

    // ============ State ============

    MockBBC internal bbc;
    MockCCIPRouter internal router;
    BoardwalkClubLockbox internal lockbox;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal peerSpoke = makeAddr("peerSpoke");
    address internal peerOther = makeAddr("peerOther");

    // ============ Events (re-declared for vm.expectEmit) ============

    event PeerSet(uint64 indexed chainSelector, address indexed peer);
    event PeersInitialized();
    event BridgeInitiated(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed from,
        address to,
        uint256 tokenId,
        uint256 fee
    );
    event BridgeReceived(
        bytes32 indexed messageId, uint64 indexed sourceChainSelector, address indexed to, uint256 tokenId
    );
    event Rescued(address indexed collection, uint256 indexed tokenId, address indexed to);
    event ForceUnlocked(uint256 indexed tokenId, address indexed to);

    // ============ Setup ============

    function setUp() public {
        bbc = new MockBBC();
        router = new MockCCIPRouter();
        lockbox = new BoardwalkClubLockbox(address(router), owner, address(bbc));

        uint64[] memory selectors = new uint64[](2);
        address[] memory peers = new address[](2);
        selectors[0] = SEL_SPOKE;
        peers[0] = peerSpoke;
        selectors[1] = SEL_OTHER;
        peers[1] = peerOther;
        vm.prank(owner);
        lockbox.initializePeers(selectors, peers);

        bbc.mint(alice, TOKEN_ID);
        vm.prank(alice);
        bbc.setApprovalForAll(address(lockbox), true);
        vm.deal(alice, 10 ether);
    }

    // ============ Helpers ============

    /// @dev Bridge `tokenId` out as alice with exact fee; returns the messageId.
    function _bridgeOut(
        uint256 tokenId
    ) internal returns (bytes32) {
        uint256 fee = router.fee();
        vm.prank(alice);
        return lockbox.bridge{value: fee}(SEL_SPOKE, tokenId, alice);
    }

    /// @dev Fresh unwired lockbox for initializePeers matrix tests.
    function _freshLockbox() internal returns (BoardwalkClubLockbox) {
        return new BoardwalkClubLockbox(address(router), owner, address(bbc));
    }

    // ============ Constructor ============

    function test_Constructor_SetsConfig() public view {
        assertEq(address(lockbox.NFT()), address(bbc), "NFT wired");
        assertEq(lockbox.getRouter(), address(router), "router wired");
        assertEq(lockbox.owner(), owner, "owner wired");
        assertEq(lockbox.FORCE_UNLOCK_DELAY(), 30 days, "force-unlock delay");
    }

    function test_Constructor_SupportsCCIPReceiverInterface() public view {
        assertTrue(lockbox.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId), "IAny2EVMMessageReceiver");
        assertTrue(lockbox.supportsInterface(0x01ffc9a7), "IERC165");
        assertFalse(lockbox.supportsInterface(0x80ac58cd), "not an ERC721");
        assertFalse(lockbox.supportsInterface(0xffffffff), "0xffffffff rejected per ERC165");
    }

    function test_RevertWhen_ConstructorNftNotContract() public {
        vm.expectRevert(BoardwalkClubLockbox.NotAContract.selector);
        new BoardwalkClubLockbox(address(router), owner, alice);
    }

    function test_RevertWhen_ConstructorRouterZero() public {
        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, address(0)));
        new BoardwalkClubLockbox(address(0), owner, address(bbc));
    }

    // ============ initializePeers ============

    function test_InitializePeers_WiresAllAndLatches() public {
        BoardwalkClubLockbox fresh = _freshLockbox();
        uint64[] memory selectors = new uint64[](1);
        address[] memory peers = new address[](1);
        selectors[0] = SEL_SPOKE;
        peers[0] = peerSpoke;

        vm.expectEmit(true, true, false, true, address(fresh));
        emit PeerSet(SEL_SPOKE, peerSpoke);
        vm.expectEmit(false, false, false, true, address(fresh));
        emit PeersInitialized();

        vm.prank(owner);
        fresh.initializePeers(selectors, peers);

        assertEq(fresh.peers(SEL_SPOKE), peerSpoke, "peer wired");
        assertTrue(fresh.peersInitialized(), "latch set");
    }

    function test_RevertWhen_InitializePeersTwice() public {
        uint64[] memory selectors = new uint64[](1);
        address[] memory peers = new address[](1);
        selectors[0] = SEL_UNKNOWN;
        peers[0] = stranger;

        vm.prank(owner);
        vm.expectRevert(BoardwalkClubLockbox.AlreadyInitialized.selector);
        lockbox.initializePeers(selectors, peers);
    }

    function test_RevertWhen_InitializePeersEmpty() public {
        BoardwalkClubLockbox fresh = _freshLockbox();
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubLockbox.EmptyArray.selector);
        fresh.initializePeers(new uint64[](0), new address[](0));
    }

    function test_RevertWhen_InitializePeersLengthMismatch() public {
        BoardwalkClubLockbox fresh = _freshLockbox();
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubLockbox.ArrayLengthMismatch.selector);
        fresh.initializePeers(new uint64[](2), new address[](1));
    }

    function test_RevertWhen_InitializePeersZeroPeer() public {
        BoardwalkClubLockbox fresh = _freshLockbox();
        uint64[] memory selectors = new uint64[](1);
        selectors[0] = SEL_SPOKE;
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubBridgeBase.ZeroAddress.selector);
        fresh.initializePeers(selectors, new address[](1));
    }

    function test_RevertWhen_InitializePeersZeroSelector() public {
        BoardwalkClubLockbox fresh = _freshLockbox();
        address[] memory peers = new address[](1);
        peers[0] = peerSpoke;
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubBridgeBase.ZeroSelector.selector);
        fresh.initializePeers(new uint64[](1), peers);
    }

    function test_RevertWhen_InitializePeersDuplicateSelector() public {
        BoardwalkClubLockbox fresh = _freshLockbox();
        uint64[] memory selectors = new uint64[](2);
        address[] memory peers = new address[](2);
        selectors[0] = SEL_SPOKE;
        peers[0] = peerSpoke;
        selectors[1] = SEL_SPOKE;
        peers[1] = peerOther;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubLockbox.DuplicateSelector.selector, SEL_SPOKE));
        fresh.initializePeers(selectors, peers);
    }

    function test_RevertWhen_InitializePeersNotOwner() public {
        BoardwalkClubLockbox fresh = _freshLockbox();
        uint64[] memory selectors = new uint64[](1);
        address[] memory peers = new address[](1);
        selectors[0] = SEL_SPOKE;
        peers[0] = peerSpoke;
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fresh.initializePeers(selectors, peers);
    }

    // ============ bridge (lock + send) ============

    function test_Bridge_LocksEscrowsAndSendsMessage() public {
        uint256 fee = router.fee();
        bytes memory expectedData = abi.encode(alice, TOKEN_ID);
        bytes32 expectedId = keccak256(abi.encode(uint256(1), SEL_SPOKE, expectedData));

        vm.expectEmit(true, true, true, true, address(lockbox));
        emit BridgeInitiated(expectedId, SEL_SPOKE, alice, alice, TOKEN_ID, fee);

        vm.prank(alice);
        bytes32 messageId = lockbox.bridge{value: fee}(SEL_SPOKE, TOKEN_ID, alice);

        assertEq(messageId, expectedId, "deterministic message id");
        assertTrue(lockbox.locked(TOKEN_ID), "escrow accounted");
        assertEq(bbc.ownerOf(TOKEN_ID), address(lockbox), "original escrowed");
        assertEq(address(lockbox).balance, 0, "lockbox holds no ETH");
        assertEq(address(router).balance, fee, "router got exactly the fee");

        // Message shape: trusted peer as receiver, 64-byte payload, native fee token,
        // GenericExtraArgsV2 with the lockbox's destination gas limit and OOO execution.
        assertEq(router.lastReceiver(), abi.encode(peerSpoke), "receiver is the peer");
        assertEq(router.lastData(), expectedData, "payload is (recipient, tokenId)");
        assertEq(router.lastFeeToken(), address(0), "native fee token");
        assertEq(
            router.lastExtraArgs(),
            Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: DEST_GAS_LIMIT, allowOutOfOrderExecution: true})),
            "extraArgs encoding"
        );
    }

    function test_Bridge_RefundsExcess() public {
        uint256 fee = router.fee();
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        lockbox.bridge{value: fee + 0.5 ether}(SEL_SPOKE, TOKEN_ID, alice);

        assertEq(alice.balance, balanceBefore - fee, "only the fee was spent");
        assertEq(address(lockbox).balance, 0, "no ETH stranded in the lockbox");
    }

    function test_Bridge_DifferentRecipient() public {
        uint256 fee = router.fee();
        vm.prank(alice);
        lockbox.bridge{value: fee}(SEL_SPOKE, TOKEN_ID, bob);

        (address to, uint256 tokenId) = abi.decode(router.lastData(), (address, uint256));
        assertEq(to, bob, "recipient routed");
        assertEq(tokenId, TOKEN_ID, "token routed");
    }

    function test_RevertWhen_BridgeInsufficientFee() public {
        uint256 fee = router.fee();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InsufficientFee.selector, fee, fee - 1));
        lockbox.bridge{value: fee - 1}(SEL_SPOKE, TOKEN_ID, alice);
    }

    function test_RevertWhen_BridgeNoPeer() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.NoPeer.selector, SEL_UNKNOWN));
        lockbox.bridge{value: 1 ether}(SEL_UNKNOWN, TOKEN_ID, alice);
    }

    function test_RevertWhen_BridgeZeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert(BoardwalkClubBridgeBase.ZeroAddress.selector);
        lockbox.bridge{value: 1 ether}(SEL_SPOKE, TOKEN_ID, address(0));
    }

    function test_RevertWhen_BridgeRecipientIsDestinationPeer() public {
        // Minting to the destination bridge contract would strand the representation there.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InvalidRecipient.selector, peerSpoke));
        lockbox.bridge{value: 1 ether}(SEL_SPOKE, TOKEN_ID, peerSpoke);
    }

    function test_RevertWhen_BridgeRecipientIsBridgeItself() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InvalidRecipient.selector, address(lockbox)));
        lockbox.bridge{value: 1 ether}(SEL_SPOKE, TOKEN_ID, address(lockbox));
    }

    function test_RevertWhen_BridgeWithoutApproval() public {
        bbc.mint(bob, 8);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(lockbox), 8));
        lockbox.bridge{value: 1 ether}(SEL_SPOKE, 8, bob);
    }

    function test_RevertWhen_BridgeNotTokenOwner() public {
        // bob (with blanket approval) tries to bridge alice's token. The collection rejects
        // the pull because `from` is not the owner; bridging is owner-only.
        vm.deal(bob, 1 ether);
        vm.startPrank(bob);
        bbc.setApprovalForAll(address(lockbox), true);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, bob, TOKEN_ID, alice));
        lockbox.bridge{value: 1 ether}(SEL_SPOKE, TOKEN_ID, bob);
        vm.stopPrank();
    }

    function test_RevertWhen_BridgeRefundFails() public {
        EthRejector rejector = new EthRejector();
        bbc.mint(address(rejector), 9);
        rejector.approveAll(bbc, address(lockbox));
        vm.deal(address(this), 1 ether);
        uint256 overpaid = router.fee() + 1;

        vm.expectRevert(BoardwalkClubBridgeBase.RefundFailed.selector);
        rejector.doBridge{value: overpaid}(lockbox, SEL_SPOKE, 9, alice);
    }

    // ============ quoteBridge ============

    function test_QuoteBridge_MatchesRouterFee() public {
        router.setFee(0.42 ether);
        assertEq(lockbox.quoteBridge(SEL_SPOKE, TOKEN_ID, alice), 0.42 ether, "quote passes through");
    }

    function test_RevertWhen_QuoteBridgeNoPeer() public {
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.NoPeer.selector, SEL_UNKNOWN));
        lockbox.quoteBridge(SEL_UNKNOWN, TOKEN_ID, alice);
    }

    // ============ ccipReceive (release) ============

    function test_CcipReceive_ReleasesLockedToken() public {
        _bridgeOut(TOKEN_ID);

        vm.expectEmit(true, true, true, true, address(lockbox));
        emit BridgeReceived(bytes32(uint256(1)), SEL_SPOKE, bob, TOKEN_ID);

        router.deliver(address(lockbox), bytes32(uint256(1)), SEL_SPOKE, peerSpoke, abi.encode(bob, TOKEN_ID));

        assertEq(bbc.ownerOf(TOKEN_ID), bob, "original released to recipient");
        assertFalse(lockbox.locked(TOKEN_ID), "escrow accounting cleared");
    }

    function test_RevertWhen_ReceiveTokenNotLocked() public {
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubLockbox.TokenNotLocked.selector, TOKEN_ID));
        router.deliver(address(lockbox), bytes32(uint256(1)), SEL_SPOKE, peerSpoke, abi.encode(alice, TOKEN_ID));
    }

    function test_RevertWhen_ReceiveWrongSender() public {
        _bridgeOut(TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InvalidPeer.selector, SEL_SPOKE, stranger));
        router.deliver(address(lockbox), bytes32(uint256(1)), SEL_SPOKE, stranger, abi.encode(alice, TOKEN_ID));
    }

    function test_RevertWhen_ReceiveUnknownSelector() public {
        _bridgeOut(TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InvalidPeer.selector, SEL_UNKNOWN, peerSpoke));
        router.deliver(address(lockbox), bytes32(uint256(1)), SEL_UNKNOWN, peerSpoke, abi.encode(alice, TOKEN_ID));
    }

    function test_RevertWhen_ReceiveZeroSenderOnUnknownSelector() public {
        // peers[unknown] == 0 and a zero-decoded sender would otherwise compare equal and pass.
        _bridgeOut(TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InvalidPeer.selector, SEL_UNKNOWN, address(0)));
        router.deliver(address(lockbox), bytes32(uint256(1)), SEL_UNKNOWN, address(0), abi.encode(alice, TOKEN_ID));
    }

    function test_RevertWhen_ReceiveNotRouter() public {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: SEL_SPOKE,
            sender: abi.encode(peerSpoke),
            data: abi.encode(alice, TOKEN_ID),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, stranger));
        lockbox.ccipReceive(message);
    }

    // ============ setPeer timelock ============

    function test_SetPeer_ExecutesAfterDelay() public {
        address newPeer = makeAddr("newPeer");
        vm.prank(owner);
        lockbox.signalSetPeer(SEL_SPOKE, newPeer);

        vm.warp(block.timestamp + 7 days);

        // Permissionless execute: params are committed by the signal's data hash.
        vm.expectEmit(true, true, false, true, address(lockbox));
        emit PeerSet(SEL_SPOKE, newPeer);
        vm.prank(stranger);
        lockbox.executeSetPeer(SEL_SPOKE, newPeer);

        assertEq(lockbox.peers(SEL_SPOKE), newPeer, "peer rotated");
    }

    function test_RevertWhen_ExecuteSetPeerTooEarly() public {
        address newPeer = makeAddr("newPeer");
        vm.prank(owner);
        lockbox.signalSetPeer(SEL_SPOKE, newPeer);

        uint256 executeTime = block.timestamp + 7 days;
        vm.warp(executeTime - 1);
        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockTooEarly.selector, executeTime));
        lockbox.executeSetPeer(SEL_SPOKE, newPeer);
    }

    function test_RevertWhen_ExecuteSetPeerExpired() public {
        address newPeer = makeAddr("newPeer");
        vm.prank(owner);
        lockbox.signalSetPeer(SEL_SPOKE, newPeer);

        uint256 expiresAt = block.timestamp + 14 days;
        vm.warp(expiresAt + 1);
        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockExpired.selector, expiresAt));
        lockbox.executeSetPeer(SEL_SPOKE, newPeer);
    }

    function test_RevertWhen_ExecuteSetPeerDataMismatch() public {
        vm.prank(owner);
        lockbox.signalSetPeer(SEL_SPOKE, makeAddr("newPeer"));

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(Timelocked.TimelockDataMismatch.selector);
        lockbox.executeSetPeer(SEL_SPOKE, makeAddr("differentPeer"));
    }

    function test_RevertWhen_ExecuteSetPeerNotSignaled() public {
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        lockbox.executeSetPeer(SEL_SPOKE, makeAddr("newPeer"));
    }

    function test_RevertWhen_ExecuteSetPeerWrongSelectorKey() public {
        // Composite action keys: a signal for one selector cannot execute another.
        address newPeer = makeAddr("newPeer");
        vm.prank(owner);
        lockbox.signalSetPeer(SEL_SPOKE, newPeer);

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        lockbox.executeSetPeer(SEL_OTHER, newPeer);
    }

    function test_RevertWhen_SignalSetPeerNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        lockbox.signalSetPeer(SEL_SPOKE, makeAddr("newPeer"));
    }

    function test_RevertWhen_SignalSetPeerZeroPeer() public {
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubBridgeBase.ZeroAddress.selector);
        lockbox.signalSetPeer(SEL_SPOKE, address(0));
    }

    function test_RevertWhen_ExecuteSetPeerZeroPeer() public {
        vm.expectRevert(BoardwalkClubBridgeBase.ZeroAddress.selector);
        lockbox.executeSetPeer(SEL_SPOKE, address(0));
    }

    function test_RevertWhen_SignalSetPeerZeroSelector() public {
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubBridgeBase.ZeroSelector.selector);
        lockbox.signalSetPeer(0, makeAddr("newPeer"));
    }

    function test_RevertWhen_ExecuteSetPeerZeroSelector() public {
        vm.expectRevert(BoardwalkClubBridgeBase.ZeroSelector.selector);
        lockbox.executeSetPeer(0, makeAddr("newPeer"));
    }

    function test_SignalSetPeer_OverwritesPending() public {
        address first = makeAddr("first");
        address second = makeAddr("second");
        vm.startPrank(owner);
        lockbox.signalSetPeer(SEL_SPOKE, first);
        lockbox.signalSetPeer(SEL_SPOKE, second);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);

        vm.expectRevert(Timelocked.TimelockDataMismatch.selector);
        lockbox.executeSetPeer(SEL_SPOKE, first);

        lockbox.executeSetPeer(SEL_SPOKE, second);
        assertEq(lockbox.peers(SEL_SPOKE), second, "latest signal wins");
    }

    function test_CancelSetPeer_ClearsPending() public {
        address newPeer = makeAddr("newPeer");
        vm.startPrank(owner);
        lockbox.signalSetPeer(SEL_SPOKE, newPeer);
        lockbox.cancelSetPeer(SEL_SPOKE);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        lockbox.executeSetPeer(SEL_SPOKE, newPeer);
    }

    function test_RevertWhen_CancelSetPeerNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        lockbox.cancelSetPeer(SEL_SPOKE);
    }

    // ============ removePeer (kill switch) ============

    function test_RemovePeer_BlocksLaneBothDirections() public {
        _bridgeOut(TOKEN_ID);

        vm.expectEmit(true, true, false, true, address(lockbox));
        emit PeerSet(SEL_SPOKE, address(0));
        vm.prank(owner);
        lockbox.removePeer(SEL_SPOKE);

        // Outbound dead.
        bbc.mint(alice, 8);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.NoPeer.selector, SEL_SPOKE));
        lockbox.bridge{value: 1 ether}(SEL_SPOKE, 8, alice);

        // Inbound dead (parks in CCIP failed state for manual execution after re-wire).
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InvalidPeer.selector, SEL_SPOKE, peerSpoke));
        router.deliver(address(lockbox), bytes32(uint256(1)), SEL_SPOKE, peerSpoke, abi.encode(alice, TOKEN_ID));
    }

    function test_RevertWhen_RemovePeerNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        lockbox.removePeer(SEL_SPOKE);
    }

    // ============ generic Timelocked surface is sealed ============

    function test_RevertWhen_GenericSignalAction() public {
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubBridgeBase.NotAuthorized.selector);
        lockbox.signalAction(bytes32("x"), bytes32("y"));
    }

    function test_RevertWhen_GenericCancelAction() public {
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubBridgeBase.NotAuthorized.selector);
        lockbox.cancelAction(bytes32("x"));
    }

    function test_RevertWhen_SignalBurnAction() public {
        bytes32 action = lockbox.ACTION_SET_PEER();
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubBridgeBase.NotAuthorized.selector);
        lockbox.signalBurnAction(action);
    }

    function test_RevertWhen_ExecuteBurnActionNeverSignalable() public {
        // Burn execute is permissionless in Timelocked, but no burn can ever be signaled here.
        bytes32 action = lockbox.ACTION_SET_PEER();
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        lockbox.executeBurnAction(action);
    }

    // ============ rescue (unaccounted assets only) ============

    function test_Rescue_UnaccountedOriginal() public {
        // Stranded: direct transfer into the lockbox, bypassing bridge().
        vm.prank(alice);
        bbc.transferFrom(alice, address(lockbox), TOKEN_ID);
        assertFalse(lockbox.locked(TOKEN_ID), "not escrow-accounted");

        vm.prank(owner);
        lockbox.signalRescue(address(bbc), TOKEN_ID, bob);
        vm.warp(block.timestamp + 7 days);

        vm.expectEmit(true, true, true, true, address(lockbox));
        emit Rescued(address(bbc), TOKEN_ID, bob);
        vm.prank(stranger);
        lockbox.executeRescue(address(bbc), TOKEN_ID, bob);

        assertEq(bbc.ownerOf(TOKEN_ID), bob, "stranded token recovered");
    }

    function test_Rescue_ForeignCollection() public {
        MockBBC foreign = new MockBBC();
        foreign.mint(address(lockbox), 1);

        vm.prank(owner);
        lockbox.signalRescue(address(foreign), 1, bob);
        vm.warp(block.timestamp + 7 days);
        lockbox.executeRescue(address(foreign), 1, bob);

        assertEq(foreign.ownerOf(1), bob, "foreign token recovered");
    }

    function test_RevertWhen_RescueLockedToken() public {
        _bridgeOut(TOKEN_ID);

        vm.prank(owner);
        lockbox.signalRescue(address(bbc), TOKEN_ID, bob);
        vm.warp(block.timestamp + 7 days);

        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubLockbox.TokenIsLocked.selector, TOKEN_ID));
        lockbox.executeRescue(address(bbc), TOKEN_ID, bob);
    }

    function test_RevertWhen_RescueTooEarly() public {
        vm.prank(alice);
        bbc.transferFrom(alice, address(lockbox), TOKEN_ID);

        vm.prank(owner);
        lockbox.signalRescue(address(bbc), TOKEN_ID, bob);

        uint256 executeTime = block.timestamp + 7 days;
        vm.warp(executeTime - 1);
        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockTooEarly.selector, executeTime));
        lockbox.executeRescue(address(bbc), TOKEN_ID, bob);
    }

    function test_RevertWhen_SignalRescueNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        lockbox.signalRescue(address(bbc), TOKEN_ID, bob);
    }

    function test_RevertWhen_SignalRescueZeroRecipient() public {
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubBridgeBase.ZeroAddress.selector);
        lockbox.signalRescue(address(bbc), TOKEN_ID, address(0));
    }

    function test_CancelRescue_ClearsPending() public {
        vm.startPrank(owner);
        lockbox.signalRescue(address(bbc), TOKEN_ID, bob);
        lockbox.cancelRescue(address(bbc), TOKEN_ID);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        lockbox.executeRescue(address(bbc), TOKEN_ID, bob);
    }

    function test_RevertWhen_CancelRescueNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        lockbox.cancelRescue(address(bbc), TOKEN_ID);
    }

    // ============ force-unlock (30-day backstop, recipient verified off-chain) ============

    function test_ForceUnlock_ReleasesAfter30Days() public {
        _bridgeOut(TOKEN_ID);

        vm.prank(owner);
        lockbox.signalForceUnlock(TOKEN_ID, alice);
        vm.warp(block.timestamp + 30 days);

        vm.expectEmit(true, true, false, true, address(lockbox));
        emit ForceUnlocked(TOKEN_ID, alice);
        vm.prank(stranger);
        lockbox.executeForceUnlock(TOKEN_ID, alice);

        assertEq(bbc.ownerOf(TOKEN_ID), alice, "escrowed original force-released");
        assertFalse(lockbox.locked(TOKEN_ID), "escrow accounting cleared");
    }

    function test_ForceUnlock_RecipientCanBeSpokeSecondaryBuyer() public {
        // alice bridges out, then sells the mirror to bob on the spoke; the lane is later
        // deprecated. The recovery must be able to target bob (the current spoke holder,
        // verified off-chain), not the depositor, who already got paid.
        _bridgeOut(TOKEN_ID);

        vm.prank(owner);
        lockbox.signalForceUnlock(TOKEN_ID, bob);
        vm.warp(block.timestamp + 30 days);
        lockbox.executeForceUnlock(TOKEN_ID, bob);

        assertEq(bbc.ownerOf(TOKEN_ID), bob, "original released to the verified spoke holder");
    }

    function test_RevertWhen_SignalForceUnlockNotLocked() public {
        // Cannot pre-arm the 30-day clock against a token that is not yet escrowed: the affected
        // holder always gets the full public window.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubLockbox.TokenNotLocked.selector, TOKEN_ID));
        lockbox.signalForceUnlock(TOKEN_ID, alice);
    }

    function test_ForceUnlock_PendingClearedOnLegitimateRelease() public {
        // A holder contests a wrongful signal by bridging back: the legitimate release clears the
        // pending signal, so it cannot fire later against a re-escrow (execute is permissionless).
        _bridgeOut(TOKEN_ID);
        vm.prank(owner);
        lockbox.signalForceUnlock(TOKEN_ID, stranger);

        // Holder bridges the mirror back, releasing the original and defeating the signal.
        router.deliver(address(lockbox), bytes32(uint256(1)), SEL_SPOKE, peerSpoke, abi.encode(alice, TOKEN_ID));
        (bool isPending,,) = lockbox.getPendingChange(keccak256(abi.encode(lockbox.ACTION_FORCE_UNLOCK(), TOKEN_ID)));
        assertFalse(isPending, "pending force-unlock cleared on release");

        // Re-escrow, wait out the original window: the stale signal is gone, execute reverts.
        vm.prank(alice);
        bbc.setApprovalForAll(address(lockbox), true);
        _bridgeOut(TOKEN_ID);
        vm.warp(block.timestamp + 37 days);
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        lockbox.executeForceUnlock(TOKEN_ID, stranger);
    }

    function test_RevertWhen_ForceUnlockBeforeThirtyDays() public {
        _bridgeOut(TOKEN_ID);

        vm.prank(owner);
        lockbox.signalForceUnlock(TOKEN_ID, alice);

        // The 7-day default delay must not apply: 30 days is hardcoded at the typed signal.
        uint256 executeTime = block.timestamp + 30 days;
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockTooEarly.selector, executeTime));
        lockbox.executeForceUnlock(TOKEN_ID, alice);
    }

    function test_RevertWhen_ForceUnlockExpired() public {
        _bridgeOut(TOKEN_ID);

        vm.prank(owner);
        lockbox.signalForceUnlock(TOKEN_ID, alice);

        uint256 expiresAt = block.timestamp + 37 days;
        vm.warp(expiresAt + 1);
        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockExpired.selector, expiresAt));
        lockbox.executeForceUnlock(TOKEN_ID, alice);
    }

    function test_RevertWhen_ForceUnlockRecipientMismatch() public {
        // The recipient is committed at signal time; execute cannot redirect it.
        _bridgeOut(TOKEN_ID);

        vm.prank(owner);
        lockbox.signalForceUnlock(TOKEN_ID, alice);
        vm.warp(block.timestamp + 30 days);

        vm.expectRevert(Timelocked.TimelockDataMismatch.selector);
        lockbox.executeForceUnlock(TOKEN_ID, bob);
    }

    function test_RevertWhen_ExecuteForceUnlockNotLocked() public {
        // Defensive execute-time guard: a never-escrowed token has no signal and is not locked.
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubLockbox.TokenNotLocked.selector, TOKEN_ID));
        lockbox.executeForceUnlock(TOKEN_ID, alice);
    }

    function test_RevertWhen_SignalForceUnlockNotOwner() public {
        _bridgeOut(TOKEN_ID);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        lockbox.signalForceUnlock(TOKEN_ID, alice);
    }

    function test_RevertWhen_SignalForceUnlockZeroRecipient() public {
        _bridgeOut(TOKEN_ID);
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubBridgeBase.ZeroAddress.selector);
        lockbox.signalForceUnlock(TOKEN_ID, address(0));
    }

    function test_CancelForceUnlock_ClearsPending() public {
        _bridgeOut(TOKEN_ID);

        vm.startPrank(owner);
        lockbox.signalForceUnlock(TOKEN_ID, alice);
        lockbox.cancelForceUnlock(TOKEN_ID);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(Timelocked.TimelockNotSignaled.selector);
        lockbox.executeForceUnlock(TOKEN_ID, alice);
    }

    function test_RevertWhen_CancelForceUnlockNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        lockbox.cancelForceUnlock(TOKEN_ID);
    }

    function test_ForceUnlock_MisuseOrphansSpokeRepresentation() public {
        // Misuse case: force-unlocking while the spoke representation still exists breaks the
        // single-representation invariant; the orphaned mirror's bridge-back then bricks.
        _bridgeOut(TOKEN_ID);

        vm.prank(owner);
        lockbox.signalForceUnlock(TOKEN_ID, bob);
        vm.warp(block.timestamp + 30 days);
        lockbox.executeForceUnlock(TOKEN_ID, bob);

        // The (conceptual) mirror burn now arrives: the release has nothing to release.
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubLockbox.TokenNotLocked.selector, TOKEN_ID));
        router.deliver(address(lockbox), bytes32(uint256(2)), SEL_SPOKE, peerSpoke, abi.encode(alice, TOKEN_ID));
    }

    // ============ Ownable2Step ============

    function test_TransferOwnership_TwoStep() public {
        vm.prank(owner);
        lockbox.transferOwnership(bob);
        assertEq(lockbox.owner(), owner, "owner unchanged until accept");

        vm.prank(bob);
        lockbox.acceptOwnership();
        assertEq(lockbox.owner(), bob, "ownership accepted");
    }

    // ============ Fuzz ============

    function testFuzz_Bridge_RefundsExcess(
        uint96 overpay
    ) public {
        uint256 fee = router.fee();
        vm.deal(alice, fee + uint256(overpay));
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        lockbox.bridge{value: fee + uint256(overpay)}(SEL_SPOKE, TOKEN_ID, alice);

        assertEq(alice.balance, balanceBefore - fee, "exactly the fee was spent");
        assertEq(address(lockbox).balance, 0, "no ETH stranded");
    }

    function testFuzz_Receive_RejectsNonPeerSender(
        address sender
    ) public {
        vm.assume(sender != peerSpoke);
        _bridgeOut(TOKEN_ID);

        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InvalidPeer.selector, SEL_SPOKE, sender));
        router.deliver(address(lockbox), bytes32(uint256(1)), SEL_SPOKE, sender, abi.encode(alice, TOKEN_ID));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {BoardwalkClubMirror} from "src/nft/BoardwalkClubMirror.sol";
import {BoardwalkClubBridgeBase} from "src/nft/BoardwalkClubBridgeBase.sol";
import {Timelocked} from "src/base/Timelocked.sol";
import {MembershipDiscount} from "src/base/MembershipDiscount.sol";

/// @dev Plain OZ ERC721 used as the parity oracle for the mirror's hardcoded supportsInterface.
contract PlainERC721 is ERC721 {
    constructor() ERC721("Plain", "PLN") {}
}

/// @dev Exposes MembershipDiscount internals to exercise the real gating path against the mirror.
contract MembershipDiscountHarness is MembershipDiscount {
    function setNftCollection(
        address nft
    ) external {
        _setNftCollection(nft);
    }

    function isMember(
        address account
    ) external view returns (bool) {
        return _isMember(account);
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

/// @title BoardwalkClubMirrorTest
/// @notice Unit and fuzz tests for the spoke-side burn/mint half of the Boardwalk Club bridge.
contract BoardwalkClubMirrorTest is Test {
    using Strings for uint256;

    // ============ Constants ============

    uint64 internal constant SEL_BASE = 5555;
    uint64 internal constant SEL_OTHER = 2222;
    uint256 internal constant TOKEN_ID = 7;
    uint256 internal constant DEST_GAS_LIMIT = 250_000;
    string internal constant BASE_URI = "ipfs://QmZrgwLmT1mSRokf2ohxuVeao3zVYYLN2AS6ds5PswXCiZ/";

    // ============ State ============

    MockCCIPRouter internal router;
    BoardwalkClubMirror internal mirror;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");
    address internal lockbox = makeAddr("lockbox");

    // ============ Events (re-declared for vm.expectEmit) ============

    event PeerSet(uint64 indexed chainSelector, address indexed peer);
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

    // ============ Setup ============

    function setUp() public {
        router = new MockCCIPRouter();
        mirror = new BoardwalkClubMirror(address(router), owner, SEL_BASE, lockbox);
        vm.deal(alice, 10 ether);
    }

    // ============ Helpers ============

    /// @dev Mint `tokenId` to `to` by delivering a lockbox message through the router.
    function _mintViaBridge(
        address to,
        uint256 tokenId
    ) internal {
        router.deliver(address(mirror), keccak256(abi.encode(tokenId)), SEL_BASE, lockbox, abi.encode(to, tokenId));
    }

    // ============ Constructor ============

    function test_Constructor_WiresBasePeerAndMetadata() public {
        vm.expectEmit(true, true, false, true);
        emit PeerSet(SEL_BASE, lockbox);
        BoardwalkClubMirror fresh = new BoardwalkClubMirror(address(router), owner, SEL_BASE, lockbox);

        assertEq(fresh.peers(SEL_BASE), lockbox, "Base peer wired at construction");
        assertEq(fresh.BASE_CHAIN_SELECTOR(), SEL_BASE, "Base selector pinned");
        assertEq(fresh.name(), "Boardwalk Beach Club", "name matches the original collection");
        assertEq(fresh.symbol(), "BBC", "symbol matches the original collection");
        assertEq(fresh.owner(), owner, "owner wired");
        assertEq(fresh.getRouter(), address(router), "router wired");
    }

    function test_RevertWhen_ConstructorZeroLockbox() public {
        vm.expectRevert(BoardwalkClubBridgeBase.ZeroAddress.selector);
        new BoardwalkClubMirror(address(router), owner, SEL_BASE, address(0));
    }

    function test_RevertWhen_ConstructorZeroSelector() public {
        vm.expectRevert(BoardwalkClubBridgeBase.ZeroSelector.selector);
        new BoardwalkClubMirror(address(router), owner, 0, lockbox);
    }

    function test_RevertWhen_ConstructorRouterZero() public {
        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, address(0)));
        new BoardwalkClubMirror(address(0), owner, SEL_BASE, lockbox);
    }

    // ============ ccipReceive (mint) ============

    function test_CcipReceive_MintsToRecipient() public {
        vm.expectEmit(true, true, true, true, address(mirror));
        emit BridgeReceived(bytes32(uint256(1)), SEL_BASE, alice, TOKEN_ID);

        router.deliver(address(mirror), bytes32(uint256(1)), SEL_BASE, lockbox, abi.encode(alice, TOKEN_ID));

        assertEq(mirror.ownerOf(TOKEN_ID), alice, "representation minted to recipient");
        assertEq(mirror.balanceOf(alice), 1, "balance drives membership gating");
    }

    function test_RevertWhen_ReceiveMintDuplicate() public {
        _mintViaBridge(alice, TOKEN_ID);

        // Unreachable under the supply invariant (the original is escrowed while the
        // representation lives), but the ERC721 itself enforces it.
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        router.deliver(address(mirror), bytes32(uint256(2)), SEL_BASE, lockbox, abi.encode(bob, TOKEN_ID));
    }

    function test_RevertWhen_ReceiveWrongSender() public {
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InvalidPeer.selector, SEL_BASE, stranger));
        router.deliver(address(mirror), bytes32(uint256(1)), SEL_BASE, stranger, abi.encode(alice, TOKEN_ID));
    }

    function test_RevertWhen_ReceiveUnknownSelector() public {
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InvalidPeer.selector, SEL_OTHER, lockbox));
        router.deliver(address(mirror), bytes32(uint256(1)), SEL_OTHER, lockbox, abi.encode(alice, TOKEN_ID));
    }

    function test_RevertWhen_ReceiveNotRouter() public {
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: SEL_BASE,
            sender: abi.encode(lockbox),
            data: abi.encode(alice, TOKEN_ID),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(CCIPReceiver.InvalidRouter.selector, stranger));
        mirror.ccipReceive(message);
    }

    // ============ Transferability (NOT soulbound) ============

    function test_Transfer_Succeeds() public {
        _mintViaBridge(alice, TOKEN_ID);

        vm.prank(alice);
        mirror.transferFrom(alice, bob, TOKEN_ID);
        assertEq(mirror.ownerOf(TOKEN_ID), bob, "standard transfer works (contrast: soulbound BoardwalkClub)");

        vm.prank(bob);
        mirror.safeTransferFrom(bob, alice, TOKEN_ID);
        assertEq(mirror.ownerOf(TOKEN_ID), alice, "safeTransferFrom works");
    }

    function test_Approve_EnablesOperatorTransfer() public {
        _mintViaBridge(alice, TOKEN_ID);

        vm.prank(alice);
        mirror.approve(bob, TOKEN_ID);
        vm.prank(bob);
        mirror.transferFrom(alice, bob, TOKEN_ID);
        assertEq(mirror.ownerOf(TOKEN_ID), bob, "approved transfer works");
    }

    // ============ Metadata ============

    function test_TokenURI_MatchesOriginalCollection() public {
        _mintViaBridge(alice, 1);
        _mintViaBridge(alice, 224);

        assertEq(mirror.tokenURI(1), string.concat(BASE_URI, "1"), "id 1 URI byte-exact, no suffix");
        assertEq(mirror.tokenURI(224), string.concat(BASE_URI, "224"), "id 224 URI byte-exact");
    }

    function test_RevertWhen_TokenURINonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, TOKEN_ID));
        mirror.tokenURI(TOKEN_ID);
    }

    // ============ supportsInterface (hardcoded pure — parity-checked) ============

    function test_SupportsInterface_ParityWithERC721AndCCIP() public {
        PlainERC721 oracle = new PlainERC721();

        // The hardcoded ids must track OZ's own answers exactly.
        bytes4[3] memory erc721Ids = [
            type(IERC721).interfaceId, // 0x80ac58cd
            type(IERC721Metadata).interfaceId, // 0x5b5e139f
            type(IERC165).interfaceId // 0x01ffc9a7
        ];
        for (uint256 i = 0; i < erc721Ids.length; ++i) {
            assertEq(
                mirror.supportsInterface(erc721Ids[i]),
                oracle.supportsInterface(erc721Ids[i]),
                "parity with plain OZ ERC721"
            );
            assertTrue(mirror.supportsInterface(erc721Ids[i]), "ERC721 surface supported");
        }

        // The offramp checks this before calling ccipReceive; returning false means the
        // delivery is marked successful without minting and the token is lost.
        assertEq(type(IAny2EVMMessageReceiver).interfaceId, bytes4(0x85572ffb), "hardcoded CCIP id matches the type");
        assertTrue(mirror.supportsInterface(0x85572ffb), "IAny2EVMMessageReceiver supported");

        assertFalse(mirror.supportsInterface(0xffffffff), "0xffffffff rejected per ERC165");
        assertFalse(mirror.supportsInterface(0xdeadbeef), "unknown id rejected");
    }

    // ============ bridge (burn + send) ============

    function test_Bridge_BurnsAndSendsMessage() public {
        _mintViaBridge(alice, TOKEN_ID);
        uint256 fee = router.fee();
        bytes memory expectedData = abi.encode(alice, TOKEN_ID);
        bytes32 expectedId = keccak256(abi.encode(uint256(1), SEL_BASE, expectedData));

        vm.expectEmit(true, true, true, true, address(mirror));
        emit BridgeInitiated(expectedId, SEL_BASE, alice, alice, TOKEN_ID, fee);

        vm.prank(alice);
        bytes32 messageId = mirror.bridge{value: fee}(SEL_BASE, TOKEN_ID, alice);

        assertEq(messageId, expectedId, "deterministic message id");
        assertEq(mirror.balanceOf(alice), 0, "representation burned");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, TOKEN_ID));
        mirror.ownerOf(TOKEN_ID);

        assertEq(router.lastReceiver(), abi.encode(lockbox), "receiver is the lockbox");
        assertEq(router.lastData(), expectedData, "payload is (recipient, tokenId)");
        assertEq(router.lastFeeToken(), address(0), "native fee token");
        assertEq(
            router.lastExtraArgs(),
            Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: DEST_GAS_LIMIT, allowOutOfOrderExecution: true})),
            "extraArgs sized for the ERC721A release on Base"
        );
        assertEq(address(mirror).balance, 0, "no ETH stranded in the mirror");
    }

    function test_Bridge_RefundsExcess() public {
        _mintViaBridge(alice, TOKEN_ID);
        uint256 fee = router.fee();
        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        mirror.bridge{value: fee + 1 ether}(SEL_BASE, TOKEN_ID, bob);

        assertEq(alice.balance, balanceBefore - fee, "only the fee was spent");
    }

    function test_RevertWhen_BridgeNotTokenOwner() public {
        _mintViaBridge(alice, TOKEN_ID);
        vm.deal(bob, 1 ether);

        vm.prank(bob);
        vm.expectRevert(BoardwalkClubMirror.NotTokenOwner.selector);
        mirror.bridge{value: 1 ether}(SEL_BASE, TOKEN_ID, bob);
    }

    function test_RevertWhen_BridgeApprovedOperatorNotHonored() public {
        // Approvals do not authorize bridging; owner-only, matching the lockbox pull on Base.
        _mintViaBridge(alice, TOKEN_ID);
        vm.prank(alice);
        mirror.approve(bob, TOKEN_ID);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(BoardwalkClubMirror.NotTokenOwner.selector);
        mirror.bridge{value: 1 ether}(SEL_BASE, TOKEN_ID, bob);
    }

    function test_RevertWhen_BridgeNonexistentToken() public {
        vm.prank(alice);
        vm.expectRevert(BoardwalkClubMirror.NotTokenOwner.selector);
        mirror.bridge{value: 1 ether}(SEL_BASE, TOKEN_ID, alice);
    }

    function test_RevertWhen_BridgeUnknownDestination() public {
        _mintViaBridge(alice, TOKEN_ID);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.NoPeer.selector, SEL_OTHER));
        mirror.bridge{value: 1 ether}(SEL_OTHER, TOKEN_ID, alice);
    }

    function test_RevertWhen_BridgeInsufficientFee() public {
        _mintViaBridge(alice, TOKEN_ID);
        uint256 fee = router.fee();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InsufficientFee.selector, fee, fee - 1));
        mirror.bridge{value: fee - 1}(SEL_BASE, TOKEN_ID, alice);
    }

    function test_RevertWhen_BridgeRecipientIsLockbox() public {
        // Releasing to the Base lockbox itself would only be recoverable via a 7-day rescue.
        _mintViaBridge(alice, TOKEN_ID);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InvalidRecipient.selector, lockbox));
        mirror.bridge{value: 1 ether}(SEL_BASE, TOKEN_ID, lockbox);
    }

    // ============ quoteBridge ============

    function test_QuoteBridge_MatchesRouterFee() public {
        router.setFee(0.42 ether);
        assertEq(mirror.quoteBridge(SEL_BASE, TOKEN_ID, alice), 0.42 ether, "quote passes through");
    }

    // ============ setPeer pinned to the Base lane ============

    function test_SetPeer_BaseSelectorRotatesAfterDelay() public {
        address newLockbox = makeAddr("newLockbox");
        vm.prank(owner);
        mirror.signalSetPeer(SEL_BASE, newLockbox);

        vm.warp(block.timestamp + 7 days);
        mirror.executeSetPeer(SEL_BASE, newLockbox);

        assertEq(mirror.peers(SEL_BASE), newLockbox, "Base peer rotated");
    }

    function test_RevertWhen_SignalSetPeerNonBaseSelector() public {
        // A mirror only ever trusts Base. Rejected at signal time, not 7 days later at execute.
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubMirror.OnlyBaseSelector.selector);
        mirror.signalSetPeer(SEL_OTHER, makeAddr("spokePeer"));
    }

    function test_RevertWhen_ExecuteSetPeerNonBaseSelector() public {
        vm.expectRevert(BoardwalkClubMirror.OnlyBaseSelector.selector);
        mirror.executeSetPeer(SEL_OTHER, makeAddr("spokePeer"));
    }

    function test_RevertWhen_ExecuteSetPeerTooEarly() public {
        address newLockbox = makeAddr("newLockbox");
        vm.prank(owner);
        mirror.signalSetPeer(SEL_BASE, newLockbox);

        uint256 executeTime = block.timestamp + 7 days;
        vm.warp(executeTime - 1);
        vm.expectRevert(abi.encodeWithSelector(Timelocked.TimelockTooEarly.selector, executeTime));
        mirror.executeSetPeer(SEL_BASE, newLockbox);
    }

    function test_RemovePeer_KillsTheLane() public {
        _mintViaBridge(alice, TOKEN_ID);

        vm.prank(owner);
        mirror.removePeer(SEL_BASE);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.NoPeer.selector, SEL_BASE));
        mirror.bridge{value: 1 ether}(SEL_BASE, TOKEN_ID, alice);

        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InvalidPeer.selector, SEL_BASE, lockbox));
        router.deliver(address(mirror), bytes32(uint256(9)), SEL_BASE, lockbox, abi.encode(bob, 42));
    }

    function test_RevertWhen_RemovePeerNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        mirror.removePeer(SEL_BASE);
    }

    // ============ generic Timelocked surface is sealed ============

    function test_RevertWhen_GenericSignalAction() public {
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubBridgeBase.NotAuthorized.selector);
        mirror.signalAction(bytes32("x"), bytes32("y"));
    }

    function test_RevertWhen_SignalBurnAction() public {
        bytes32 action = mirror.ACTION_SET_PEER();
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubBridgeBase.NotAuthorized.selector);
        mirror.signalBurnAction(action);
    }

    function test_RevertWhen_RenounceOwnership() public {
        // Renouncing would brick the kill switch (the mirror's only safety lever).
        vm.prank(owner);
        vm.expectRevert(BoardwalkClubBridgeBase.RenounceDisabled.selector);
        mirror.renounceOwnership();
        assertEq(mirror.owner(), owner, "owner intact");
    }

    // ============ Membership discount integration ============

    function test_Integration_MembershipGatingFollowsBridgedToken() public {
        // The migration end state: a spoke's nftCollection points at the mirror, so membership
        // follows the bridged token in and out.
        MembershipDiscountHarness disc = new MembershipDiscountHarness();
        disc.setNftCollection(address(mirror));

        assertFalse(disc.isMember(alice), "no membership before bridging in");

        _mintViaBridge(alice, TOKEN_ID);
        assertTrue(disc.isMember(alice), "membership active while the representation is held");

        uint256 fee = router.fee();
        vm.prank(alice);
        mirror.bridge{value: fee}(SEL_BASE, TOKEN_ID, alice);
        assertFalse(disc.isMember(alice), "membership leaves with the token");
    }

    // ============ Fuzz ============

    function testFuzz_TokenURI(
        uint256 tokenId
    ) public {
        tokenId = bound(tokenId, 1, 224);
        _mintViaBridge(alice, tokenId);
        assertEq(mirror.tokenURI(tokenId), string.concat(BASE_URI, tokenId.toString()), "URI matches original");
    }

    function testFuzz_Receive_RejectsNonPeerSender(
        address sender
    ) public {
        vm.assume(sender != lockbox);
        vm.expectRevert(abi.encodeWithSelector(BoardwalkClubBridgeBase.InvalidPeer.selector, SEL_BASE, sender));
        router.deliver(address(mirror), bytes32(uint256(1)), SEL_BASE, sender, abi.encode(alice, TOKEN_ID));
    }

    function testFuzz_RoundTripOnSpoke_MintBurn(
        uint256 tokenId
    ) public {
        tokenId = bound(tokenId, 1, 224);
        _mintViaBridge(alice, tokenId);

        uint256 fee = router.fee();
        vm.prank(alice);
        mirror.bridge{value: fee}(SEL_BASE, tokenId, alice);

        assertEq(mirror.balanceOf(alice), 0, "burned after bridge-back");
        (address to, uint256 sentId) = abi.decode(router.lastData(), (address, uint256));
        assertEq(to, alice, "release recipient");
        assertEq(sentId, tokenId, "release token id");
    }
}

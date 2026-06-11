// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {BoardwalkClubLockbox} from "src/nft/BoardwalkClubLockbox.sol";
import {BoardwalkClubMirror} from "src/nft/BoardwalkClubMirror.sol";

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

/// @dev Router that delivers each `ccipSend` synchronously to the receiver encoded in the
///      message, reporting the sender's registered chain selector. Wires all "chains" into
///      one EVM for round-trip tests; keeps the `msg.value == fee` check.
contract LoopbackCCIPRouter {
    error FeeMismatch();

    uint256 public fee = 0.01 ether;
    uint256 public sendCount;

    /// @dev Bridge contract => the chain selector it "lives on".
    mapping(address => uint64) public chainOf;

    function setChain(
        address bridgeContract,
        uint64 chainSelector
    ) external {
        chainOf[bridgeContract] = chainSelector;
    }

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    ) external view returns (uint256) {
        return fee;
    }

    function ccipSend(
        uint64,
        Client.EVM2AnyMessage calldata message
    ) external payable returns (bytes32 messageId) {
        if (msg.value != fee) revert FeeMismatch();
        unchecked {
            ++sendCount;
        }
        messageId = keccak256(abi.encode(sendCount));

        IAny2EVMMessageReceiver(abi.decode(message.receiver, (address)))
            .ccipReceive(
                Client.Any2EVMMessage({
                    messageId: messageId,
                    sourceChainSelector: chainOf[msg.sender],
                    sender: abi.encode(msg.sender),
                    data: message.data,
                    destTokenAmounts: new Client.EVMTokenAmount[](0)
                })
            );
    }
}

/// @title BoardwalkClubBridgeRoundTripTest
/// @notice End-to-end round trips across the full topology: the Base lockbox plus two spoke
///         mirrors sharing a loopback router, asserting the single-representation invariant
///         after every hop.
contract BoardwalkClubBridgeRoundTripTest is Test {
    // ============ Constants ============

    uint64 internal constant SEL_BASE = 1000;
    uint64 internal constant SEL_SPOKE_A = 2000;
    uint64 internal constant SEL_SPOKE_B = 3000;
    uint256 internal constant TOKEN_ID = 17;

    // ============ State ============

    MockBBC internal bbc;
    LoopbackCCIPRouter internal router;
    BoardwalkClubLockbox internal lockbox;
    BoardwalkClubMirror internal mirrorA;
    BoardwalkClubMirror internal mirrorB;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // ============ Setup ============

    function setUp() public {
        bbc = new MockBBC();
        router = new LoopbackCCIPRouter();

        lockbox = new BoardwalkClubLockbox(address(router), owner, address(bbc));
        mirrorA = new BoardwalkClubMirror(address(router), owner, SEL_BASE, address(lockbox));
        mirrorB = new BoardwalkClubMirror(address(router), owner, SEL_BASE, address(lockbox));

        router.setChain(address(lockbox), SEL_BASE);
        router.setChain(address(mirrorA), SEL_SPOKE_A);
        router.setChain(address(mirrorB), SEL_SPOKE_B);

        uint64[] memory selectors = new uint64[](2);
        address[] memory peers = new address[](2);
        selectors[0] = SEL_SPOKE_A;
        peers[0] = address(mirrorA);
        selectors[1] = SEL_SPOKE_B;
        peers[1] = address(mirrorB);
        vm.prank(owner);
        lockbox.initializePeers(selectors, peers);

        bbc.mint(alice, TOKEN_ID);
        vm.prank(alice);
        bbc.setApprovalForAll(address(lockbox), true);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    // ============ Helpers ============

    /// @dev Single-representation invariant: the original is escrowed iff `locked` is set iff
    ///      exactly one representation (original-with-holder or one spoke mirror) is live; and
    ///      no bridge contract ever retains ETH.
    function _assertInvariants(
        uint256 tokenId
    ) internal view {
        bool escrowed = bbc.ownerOf(tokenId) == address(lockbox);
        assertEq(lockbox.locked(tokenId), escrowed, "locked accounting tracks escrow exactly");

        uint256 liveMirrors;
        if (_exists(mirrorA, tokenId)) liveMirrors++;
        if (_exists(mirrorB, tokenId)) liveMirrors++;
        assertEq(liveMirrors, escrowed ? 1 : 0, "exactly one live representation");

        assertEq(address(lockbox).balance, 0, "lockbox holds no ETH");
        assertEq(address(mirrorA).balance, 0, "mirrorA holds no ETH");
        assertEq(address(mirrorB).balance, 0, "mirrorB holds no ETH");
    }

    function _exists(
        BoardwalkClubMirror mirror,
        uint256 tokenId
    ) internal view returns (bool) {
        try mirror.ownerOf(tokenId) {
            return true;
        } catch {
            return false;
        }
    }

    // ============ Round trips ============

    function test_RoundTrip_BaseToSpokeAndBack() public {
        uint256 fee = router.fee();

        // Base -> spoke A: original escrowed, mirror minted in the same tx (loopback).
        vm.prank(alice);
        lockbox.bridge{value: fee}(SEL_SPOKE_A, TOKEN_ID, alice);

        assertEq(bbc.ownerOf(TOKEN_ID), address(lockbox), "original escrowed");
        assertEq(mirrorA.ownerOf(TOKEN_ID), alice, "mirror minted on spoke A");
        _assertInvariants(TOKEN_ID);

        // Spoke A -> Base: mirror burned, original released to the same holder.
        vm.prank(alice);
        mirrorA.bridge{value: fee}(SEL_BASE, TOKEN_ID, alice);

        assertEq(bbc.ownerOf(TOKEN_ID), alice, "original restored to alice");
        assertFalse(lockbox.locked(TOKEN_ID), "escrow accounting cleared");
        assertFalse(_exists(mirrorA, TOKEN_ID), "mirror burned");
        _assertInvariants(TOKEN_ID);
    }

    function test_RoundTrip_RecipientDiffersFromSender() public {
        uint256 fee = router.fee();

        vm.prank(alice);
        lockbox.bridge{value: fee}(SEL_SPOKE_A, TOKEN_ID, bob);
        assertEq(mirrorA.ownerOf(TOKEN_ID), bob, "mirror minted to bob");
        _assertInvariants(TOKEN_ID);

        // The spoke holder controls the bridge-back and can route the original to anyone.
        vm.prank(bob);
        mirrorA.bridge{value: fee}(SEL_BASE, TOKEN_ID, alice);
        assertEq(bbc.ownerOf(TOKEN_ID), alice, "original released to alice");
        _assertInvariants(TOKEN_ID);
    }

    function test_TwoHop_SpokeToSpokeViaBase() public {
        uint256 fee = router.fee();

        // Base -> A.
        vm.prank(alice);
        lockbox.bridge{value: fee}(SEL_SPOKE_A, TOKEN_ID, alice);
        _assertInvariants(TOKEN_ID);

        // Hop 1: A -> Base (back to self).
        vm.prank(alice);
        mirrorA.bridge{value: fee}(SEL_BASE, TOKEN_ID, alice);
        _assertInvariants(TOKEN_ID);

        // Hop 2: Base -> B.
        vm.prank(alice);
        lockbox.bridge{value: fee}(SEL_SPOKE_B, TOKEN_ID, alice);

        assertEq(mirrorB.ownerOf(TOKEN_ID), alice, "representation landed on spoke B");
        assertFalse(_exists(mirrorA, TOKEN_ID), "spoke A representation gone");
        assertEq(bbc.ownerOf(TOKEN_ID), address(lockbox), "original escrowed throughout hop 2");
        _assertInvariants(TOKEN_ID);
    }

    function test_RoundTrip_SpokeTransferThenBridgeBack() public {
        uint256 fee = router.fee();

        vm.prank(alice);
        lockbox.bridge{value: fee}(SEL_SPOKE_A, TOKEN_ID, alice);

        // The mirror is a normal transferable ERC721 on the spoke; the new holder bridges back.
        vm.prank(alice);
        mirrorA.transferFrom(alice, bob, TOKEN_ID);
        _assertInvariants(TOKEN_ID);

        vm.prank(bob);
        mirrorA.bridge{value: fee}(SEL_BASE, TOKEN_ID, bob);
        assertEq(bbc.ownerOf(TOKEN_ID), bob, "ownership change on the spoke followed the token home");
        _assertInvariants(TOKEN_ID);
    }

    function test_RoundTrip_RepeatedAcrossSameLane() public {
        uint256 fee = router.fee();

        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(alice);
            lockbox.bridge{value: fee}(SEL_SPOKE_A, TOKEN_ID, alice);
            _assertInvariants(TOKEN_ID);

            vm.prank(alice);
            mirrorA.bridge{value: fee}(SEL_BASE, TOKEN_ID, alice);
            _assertInvariants(TOKEN_ID);
        }
        assertEq(bbc.ownerOf(TOKEN_ID), alice, "stable across repeated round trips");
    }

    // ============ Fuzz ============

    function testFuzz_RoundTrip_TokenId(
        uint256 tokenId
    ) public {
        tokenId = bound(tokenId, 1, 224);
        vm.assume(tokenId != TOKEN_ID);
        bbc.mint(alice, tokenId);

        uint256 fee = router.fee();
        vm.prank(alice);
        lockbox.bridge{value: fee}(SEL_SPOKE_A, tokenId, alice);
        _assertInvariants(tokenId);

        vm.prank(alice);
        mirrorA.bridge{value: fee}(SEL_BASE, tokenId, alice);
        assertEq(bbc.ownerOf(tokenId), alice, "round trip restores the original");
        _assertInvariants(tokenId);
    }

    function testFuzz_RoundTrip_WithExcessFees(
        uint96 overpayOut,
        uint96 overpayBack
    ) public {
        uint256 fee = router.fee();
        vm.deal(alice, fee * 2 + uint256(overpayOut) + uint256(overpayBack));

        vm.prank(alice);
        lockbox.bridge{value: fee + uint256(overpayOut)}(SEL_SPOKE_A, TOKEN_ID, alice);
        _assertInvariants(TOKEN_ID);

        vm.prank(alice);
        mirrorA.bridge{value: fee + uint256(overpayBack)}(SEL_BASE, TOKEN_ID, alice);
        _assertInvariants(TOKEN_ID);

        assertEq(alice.balance, uint256(overpayOut) + uint256(overpayBack), "all excess refunded");
    }
}

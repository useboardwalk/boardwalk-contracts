// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BoardwalkClub} from "src/nft/BoardwalkClub.sol";
import {MembershipDiscount} from "src/base/MembershipDiscount.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev Recipient without onERC721Received; proves the non-safe mint does not revert.
contract NonReceiver {}

/// @dev Exposes MembershipDiscount internals to exercise the real discount consumption path.
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

    function effectiveCost(
        uint256 baseCost,
        uint256 discountBps,
        address account
    ) external view returns (uint256) {
        return _effectiveCost(baseCost, discountBps, account);
    }
}

/// @title BoardwalkClubTest
/// @notice Unit and fuzz tests for the soulbound BoardwalkClub membership NFT.
contract BoardwalkClubTest is Test {
    // ============ State ============

    BoardwalkClub internal nft;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    string internal constant EXPECTED_URI = "ipfs://bafkreihqzbvqdrajswauuypexczvjfwe4ii7jdxbaujfoz7mnqp3h62ud4";

    // ============ Setup ============

    function setUp() public {
        nft = new BoardwalkClub(owner);
    }

    // ============ Minting ============

    function test_Mint_OwnerMintsAndBalanceGrantsMembership() public {
        vm.prank(owner);
        uint256 id0 = nft.mint(alice);

        assertEq(id0, 0, "first id is 0");
        assertEq(nft.ownerOf(0), alice, "alice owns token 0");
        assertEq(nft.balanceOf(alice), 1, "alice balance is 1");
        assertEq(nft.nextTokenId(), 1, "nextTokenId advanced");

        vm.prank(owner);
        uint256 id1 = nft.mint(bob);

        assertEq(id1, 1, "ids increment sequentially");
        assertEq(nft.balanceOf(bob), 1, "bob balance is 1");
        assertEq(nft.nextTokenId(), 2, "nextTokenId advanced again");
    }

    function test_BatchMint_AllRecipientsReceiveOne() public {
        NonReceiver nr = new NonReceiver();

        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = address(nr);

        vm.prank(owner);
        nft.batchMint(recipients);

        assertEq(nft.balanceOf(alice), 1, "alice got one");
        assertEq(nft.balanceOf(bob), 1, "bob got one");
        assertEq(nft.balanceOf(address(nr)), 1, "non-receiver contract got one (no revert)");
        assertEq(nft.totalSupply(), 3, "total supply is 3");
        assertEq(nft.nextTokenId(), 3, "nextTokenId is 3");
        assertEq(nft.ownerOf(0), alice, "id 0 -> alice");
        assertEq(nft.ownerOf(2), address(nr), "id 2 -> non-receiver");
    }

    function test_RevertWhen_NonOwnerMints() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.mint(alice);
    }

    function test_RevertWhen_NonOwnerBatchMints() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.batchMint(recipients);
    }

    // ============ Soulbound: transfers ============

    function test_RevertWhen_TransferFrom() public {
        vm.prank(owner);
        nft.mint(alice);

        vm.prank(alice);
        vm.expectRevert(BoardwalkClub.NonTransferable.selector);
        nft.transferFrom(alice, bob, 0);
    }

    function test_RevertWhen_SafeTransferFrom() public {
        vm.prank(owner);
        nft.mint(alice);

        vm.prank(alice);
        vm.expectRevert(BoardwalkClub.NonTransferable.selector);
        nft.safeTransferFrom(alice, bob, 0);

        vm.prank(alice);
        vm.expectRevert(BoardwalkClub.NonTransferable.selector);
        nft.safeTransferFrom(alice, bob, 0, "");
    }

    // ============ Soulbound: approvals cannot be acted on ============

    function test_Approve_DoesNotEnableTransfer() public {
        vm.prank(owner);
        nft.mint(alice);

        vm.prank(alice);
        nft.approve(bob, 0);
        assertEq(nft.getApproved(0), bob, "approval recorded");

        // Approval is set but cannot be acted on.
        vm.prank(bob);
        vm.expectRevert(BoardwalkClub.NonTransferable.selector);
        nft.transferFrom(alice, bob, 0);
    }

    function test_SetApprovalForAll_DoesNotEnableTransfer() public {
        vm.prank(owner);
        nft.mint(alice);

        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        assertTrue(nft.isApprovedForAll(alice, bob), "operator approval recorded");

        vm.prank(bob);
        vm.expectRevert(BoardwalkClub.NonTransferable.selector);
        nft.transferFrom(alice, bob, 0);
    }

    // ============ Ownership ============

    function test_RenounceOwnership_RelinquishesOwnership() public {
        vm.prank(owner);
        nft.renounceOwnership();
        assertEq(nft.owner(), address(0), "ownership renounced (OZ default)");
    }

    // ============ Metadata ============

    function test_TokenURI_ReturnsSharedURIForAllTokens() public {
        vm.startPrank(owner);
        nft.mint(alice);
        nft.mint(bob);
        vm.stopPrank();

        assertEq(nft.tokenURI(0), EXPECTED_URI, "token 0 shares the URI");
        assertEq(nft.tokenURI(1), EXPECTED_URI, "token 1 shares the same URI");
    }

    function test_RevertWhen_TokenURINonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(0)));
        nft.tokenURI(0);
    }

    // ============ Enumerable ============

    function test_Enumerable_TotalSupply() public {
        assertEq(nft.totalSupply(), 0, "starts empty");

        vm.startPrank(owner);
        nft.mint(alice);
        nft.mint(bob);
        vm.stopPrank();

        assertEq(nft.totalSupply(), 2, "two minted");
        assertEq(nft.tokenOfOwnerByIndex(alice, 0), 0, "alice index 0 -> token 0");
        assertEq(nft.tokenByIndex(1), 1, "global index 1 -> token 1");
    }

    // ============ Membership discount integration ============

    function test_Integration_MembershipDiscountRecognizesHolder() public {
        MembershipDiscountHarness disc = new MembershipDiscountHarness();
        disc.setNftCollection(address(nft));

        assertFalse(disc.isMember(alice), "alice not a member yet");
        assertEq(disc.effectiveCost(1000, 2500, alice), 1000, "non-member pays full cost");

        vm.prank(owner);
        nft.mint(alice);

        // Member now gets the 25% discount (1000 -> 750).
        assertTrue(disc.isMember(alice), "alice is a member after mint");
        assertEq(disc.effectiveCost(1000, 2500, alice), 750, "member receives discount");
    }

    // ============ Fuzz ============

    function testFuzz_BatchMint(
        address[] calldata recipients
    ) public {
        // Exclude zero-address recipients (invalid for ERC721 mint).
        for (uint256 i; i < recipients.length; ++i) {
            vm.assume(recipients[i] != address(0));
        }

        vm.prank(owner);
        nft.batchMint(recipients);

        assertEq(nft.totalSupply(), recipients.length, "supply equals recipient count");
        assertEq(nft.nextTokenId(), recipients.length, "nextTokenId equals recipient count");
    }
}

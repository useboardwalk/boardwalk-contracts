// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {BWLK} from "src/token/BWLK.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BWLKTest is Test {
    BWLK public bwlk;

    address public recipient = makeAddr("recipient");
    address public ccipAdmin = makeAddr("ccipAdmin");
    address public alice = makeAddr("alice");

    uint256 internal constant MAX_SUPPLY = 3_150_000e18;

    function setUp() public {
        bwlk = new BWLK(recipient, ccipAdmin);
    }

    function test_Constructor_MintsFullSupplyToRecipient() public view {
        assertEq(bwlk.totalSupply(), MAX_SUPPLY, "total supply");
        assertEq(bwlk.balanceOf(recipient), MAX_SUPPLY, "recipient balance");
        assertEq(bwlk.MAX_SUPPLY(), MAX_SUPPLY, "MAX_SUPPLY constant");
    }

    function test_Constructor_SetsCcipAdmin() public view {
        assertEq(bwlk.getCCIPAdmin(), ccipAdmin, "ccip admin");
    }

    function test_Constructor_Metadata() public view {
        assertEq(bwlk.name(), "Boardwalk", "name");
        assertEq(bwlk.symbol(), "BWLK", "symbol");
        assertEq(bwlk.decimals(), 18, "decimals");
    }

    function test_RevertWhen_ZeroRecipient() public {
        vm.expectRevert(BWLK.ZeroAddress.selector);
        new BWLK(address(0), ccipAdmin);
    }

    function test_RevertWhen_ZeroCcipAdmin() public {
        vm.expectRevert(BWLK.ZeroAddress.selector);
        new BWLK(recipient, address(0));
    }

    function test_Transfer_Works() public {
        vm.prank(recipient);
        bwlk.transfer(alice, 1_000e18);
        assertEq(bwlk.balanceOf(alice), 1_000e18, "alice balance");
        assertEq(bwlk.balanceOf(recipient), MAX_SUPPLY - 1_000e18, "recipient balance");
    }

    function test_NoMinter_TotalSupplyFixed() public {
        // There is no mint function; supply can only ever be MAX_SUPPLY. Distribution is by transfer.
        vm.prank(recipient);
        bwlk.transfer(alice, MAX_SUPPLY);
        assertEq(bwlk.totalSupply(), MAX_SUPPLY, "supply unchanged by transfers");
        assertEq(bwlk.balanceOf(alice), MAX_SUPPLY, "alice holds all");
    }

    function testFuzz_Transfer(
        uint256 amount
    ) public {
        amount = bound(amount, 0, MAX_SUPPLY);
        vm.prank(recipient);
        bwlk.transfer(alice, amount);
        assertEq(bwlk.balanceOf(alice), amount);
        assertEq(bwlk.balanceOf(recipient), MAX_SUPPLY - amount);
    }
}

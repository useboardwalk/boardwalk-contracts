// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {BWS} from "src/token/BWS.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BWSTest is Test {
    BWS public bws;

    address public recipient = makeAddr("recipient");
    address public ccipAdmin = makeAddr("ccipAdmin");
    address public alice = makeAddr("alice");

    uint256 internal constant MAX_SUPPLY = 3_150_000e18;

    function setUp() public {
        bws = new BWS(recipient, ccipAdmin);
    }

    function test_Constructor_MintsFullSupplyToRecipient() public view {
        assertEq(bws.totalSupply(), MAX_SUPPLY, "total supply");
        assertEq(bws.balanceOf(recipient), MAX_SUPPLY, "recipient balance");
        assertEq(bws.MAX_SUPPLY(), MAX_SUPPLY, "MAX_SUPPLY constant");
    }

    function test_Constructor_SetsCcipAdmin() public view {
        assertEq(bws.getCCIPAdmin(), ccipAdmin, "ccip admin");
    }

    function test_Constructor_Metadata() public view {
        assertEq(bws.name(), "Boardwalk", "name");
        assertEq(bws.symbol(), "BWS", "symbol");
        assertEq(bws.decimals(), 18, "decimals");
    }

    function test_RevertWhen_ZeroRecipient() public {
        vm.expectRevert(BWS.ZeroAddress.selector);
        new BWS(address(0), ccipAdmin);
    }

    function test_RevertWhen_ZeroCcipAdmin() public {
        vm.expectRevert(BWS.ZeroAddress.selector);
        new BWS(recipient, address(0));
    }

    function test_Transfer_Works() public {
        vm.prank(recipient);
        bws.transfer(alice, 1_000e18);
        assertEq(bws.balanceOf(alice), 1_000e18, "alice balance");
        assertEq(bws.balanceOf(recipient), MAX_SUPPLY - 1_000e18, "recipient balance");
    }

    function test_NoMinter_TotalSupplyFixed() public {
        // There is no mint function; supply can only ever be MAX_SUPPLY. Distribution is by transfer.
        vm.prank(recipient);
        bws.transfer(alice, MAX_SUPPLY);
        assertEq(bws.totalSupply(), MAX_SUPPLY, "supply unchanged by transfers");
        assertEq(bws.balanceOf(alice), MAX_SUPPLY, "alice holds all");
    }

    function testFuzz_Transfer(
        uint256 amount
    ) public {
        amount = bound(amount, 0, MAX_SUPPLY);
        vm.prank(recipient);
        bws.transfer(alice, amount);
        assertEq(bws.balanceOf(alice), amount);
        assertEq(bws.balanceOf(recipient), MAX_SUPPLY - amount);
    }
}

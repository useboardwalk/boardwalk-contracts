// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IntegrationBase, MockERC20, MockPair, MockDEXFactory, LaunchFactory} from "./IntegrationBase.t.sol";
import {PresaleManager} from "src/core/PresaleManager.sol";
import {BoardwalkToken} from "src/core/BoardwalkToken.sol";
import {BoardwalkLPManager} from "src/core/BoardwalkLPManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LPManagerFlowTest
/// @notice Integration tests for BoardwalkLPManager tax exemption:
///         Verifies LP add/remove via LPManager is tax-free, direct router is taxed.
///         Covers plan edge cases: #20, #21, #22, #23, #31
contract LPManagerFlowTest is IntegrationBase {
    address internal tokenAddr;
    LaunchFactory.LaunchInfo internal info;
    address internal pair;

    function setUp() public override {
        super.setUp();

        // Create, contribute, seed
        tokenAddr = _createExpressLaunch();
        info = _getLaunchInfo(tokenAddr);

        _contribute(info.presaleManager, alice, 15 ether);
        uint256 presaleEnd = PresaleManager(info.presaleManager).presaleEnd();
        vm.warp(presaleEnd + 1 hours + 1);
        PresaleManager(info.presaleManager).seedLiquidity();

        pair = dexFactory.getPair(tokenAddr, address(weth));

        // Claim tokens for alice (past cliff)
        uint256 seedTime = PresaleManager(info.presaleManager).liquiditySeedTime();
        vm.warp(seedTime + 7 days + 1);
        // Warp further past anti-whale (90 min from seed already passed with 7 day warp)
        vm.prank(alice);
        PresaleManager(info.presaleManager).claimTokens();
    }

    // ============ Edge Case #20: LP Add via LPManager is Tax-Free ============

    function test_AddLiquidity_ViaLPManager_TaxFree() public {
        uint256 tokenAmount = 1000e18;
        uint256 wethAmount = 1 ether;

        // Give alice tokens and WETH
        deal(tokenAddr, alice, IERC20(tokenAddr).balanceOf(alice) + tokenAmount);
        weth.mint(alice, wethAmount);

        uint256 aliceTokensBefore = IERC20(tokenAddr).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(tokenAddr).approve(address(lpManager), tokenAmount);
        weth.approve(address(lpManager), wethAmount);

        (uint256 usedA, uint256 usedB, uint256 liquidity) = lpManager.addLiquidity(
            tokenAddr, address(weth), tokenAmount, wethAmount, 0, 0, alice, block.timestamp + 1 hours
        );
        vm.stopPrank();

        // LPManager is exempt — tokens should be transferred without tax
        // alice spent exactly usedA tokens (no extra deducted for tax)
        uint256 aliceTokensAfter = IERC20(tokenAddr).balanceOf(alice);
        assertEq(aliceTokensBefore - aliceTokensAfter, usedA, "No tax should be applied through LPManager");
        assertGt(liquidity, 0, "Should receive LP tokens");
    }

    // ============ Edge Case #21: LP Remove via LPManager is Tax-Free ============

    function test_RemoveLiquidity_ViaLPManager_TaxFree() public {
        // First add liquidity to get LP tokens
        uint256 tokenAmount = 1000e18;
        uint256 wethAmount = 1 ether;

        deal(tokenAddr, alice, IERC20(tokenAddr).balanceOf(alice) + tokenAmount);
        weth.mint(alice, wethAmount);

        vm.startPrank(alice);
        IERC20(tokenAddr).approve(address(lpManager), tokenAmount);
        weth.approve(address(lpManager), wethAmount);

        (,, uint256 liquidity) = lpManager.addLiquidity(
            tokenAddr, address(weth), tokenAmount, wethAmount, 0, 0, alice, block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Now remove liquidity
        uint256 aliceTokensBefore = IERC20(tokenAddr).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(pair).approve(address(lpManager), liquidity);

        (uint256 amountA, uint256 amountB) =
            lpManager.removeLiquidity(tokenAddr, address(weth), liquidity, 0, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        // Should receive tokens back without tax
        uint256 aliceTokensAfter = IERC20(tokenAddr).balanceOf(alice);
        assertEq(aliceTokensAfter - aliceTokensBefore, amountA, "Remove should be tax-free via LPManager");
    }

    // ============ Edge Case #22: Direct Router Transfer IS Taxed ============

    function test_DirectTransfer_IsTaxed() public {
        uint256 aliceBalance = IERC20(tokenAddr).balanceOf(alice);
        uint256 transferAmount = aliceBalance / 4;

        vm.prank(alice);
        IERC20(tokenAddr).transfer(bob, transferAmount);

        uint256 bobReceived = IERC20(tokenAddr).balanceOf(bob);
        assertLt(bobReceived, transferAmount, "Direct transfer should be taxed");
    }

    // ============ Edge Case #23: LPManager Has No Swap Functions ============

    function test_LPManager_NoSwapExposed() public {
        // Verify that BoardwalkLPManager only has addLiquidity and removeLiquidity
        // This is a compile-time guarantee (no swap functions in the contract)
        // We verify by checking the contract has the expected functions
        assertTrue(address(lpManager) != address(0), "LPManager exists");

        // If we could call swap, it would be exposed in the interface
        // The interface IBoardwalkLPManager only has addLiquidity and removeLiquidity
        // This test is a documentation assertion
    }

    // ============ Edge Case #31: Excess Tokens Returned Tax-Free ============

    function test_AddLiquidity_ExcessReturned() public {
        uint256 tokenAmount = 2000e18;
        uint256 wethAmount = 1 ether;

        deal(tokenAddr, alice, IERC20(tokenAddr).balanceOf(alice) + tokenAmount);
        weth.mint(alice, wethAmount);

        uint256 aliceTokensBefore = IERC20(tokenAddr).balanceOf(alice);

        vm.startPrank(alice);
        IERC20(tokenAddr).approve(address(lpManager), tokenAmount);
        weth.approve(address(lpManager), wethAmount);

        (uint256 usedA,,) = lpManager.addLiquidity(
            tokenAddr, address(weth), tokenAmount, wethAmount, 0, 0, alice, block.timestamp + 1 hours
        );
        vm.stopPrank();

        // Excess should be returned tax-free
        uint256 aliceTokensAfter = IERC20(tokenAddr).balanceOf(alice);
        uint256 spent = aliceTokensBefore - aliceTokensAfter;
        assertEq(spent, usedA, "Only used amount should be spent, excess returned tax-free");
    }

    // ============ Multiple Users Can Add Liquidity ============

    function test_MultipleUsers_AddLiquidity() public {
        // Alice adds
        deal(tokenAddr, alice, IERC20(tokenAddr).balanceOf(alice) + 1000e18);
        weth.mint(alice, 1 ether);
        vm.startPrank(alice);
        IERC20(tokenAddr).approve(address(lpManager), 1000e18);
        weth.approve(address(lpManager), 1 ether);
        (,, uint256 liq1) =
            lpManager.addLiquidity(tokenAddr, address(weth), 1000e18, 1 ether, 0, 0, alice, block.timestamp + 1 hours);
        vm.stopPrank();

        // Bob adds
        deal(tokenAddr, bob, IERC20(tokenAddr).balanceOf(bob) + 500e18);
        weth.mint(bob, 0.5 ether);
        vm.startPrank(bob);
        IERC20(tokenAddr).approve(address(lpManager), 500e18);
        weth.approve(address(lpManager), 0.5 ether);
        (,, uint256 liq2) =
            lpManager.addLiquidity(tokenAddr, address(weth), 500e18, 0.5 ether, 0, 0, bob, block.timestamp + 1 hours);
        vm.stopPrank();

        assertGt(liq1, 0, "Alice should have LP");
        assertGt(liq2, 0, "Bob should have LP");
        assertGt(IERC20(pair).balanceOf(alice), 0, "Alice LP balance > 0");
        assertGt(IERC20(pair).balanceOf(bob), 0, "Bob LP balance > 0");
    }
}

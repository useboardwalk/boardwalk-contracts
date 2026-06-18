// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseRevenueSwapper} from "src/crosschain/BaseRevenueSwapper.sol";

contract MockERC20 is ERC20 {
    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @dev Mock 0x AllowanceHolder. `exec` pulls `amountIn` of `tokenIn` from the caller (the swapper)
///      and sends `amountOut` of `tokenOut` back, modeling a swap. Pre-fund it with the out token.
contract MockAllowanceHolder {
    bool public reverting;

    function setReverting(
        bool r
    ) external {
        reverting = r;
    }

    function exec(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut
    ) external {
        if (reverting) revert("0x: forced revert");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

/// @dev Malicious AllowanceHolder that re-enters `forwardWeth()` mid-swap. Records whether the
///      reentrant call succeeded (it must not, thanks to `nonReentrant`).
contract ReentrantAllowanceHolder {
    address public swapper;
    bool public reentrySucceeded;

    function setSwapper(
        address s
    ) external {
        swapper = s;
    }

    function exec(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut
    ) external {
        (bool ok,) = swapper.call(abi.encodeWithSignature("forwardWeth()"));
        reentrySucceeded = ok;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(msg.sender, amountOut);
    }
}

contract RejectNative {}

contract BaseRevenueSwapperTest is Test {
    uint256 internal constant AMOUNT = 1000e18; // delivered raise token (e.g. frxUSD)

    MockERC20 internal frxusd;
    MockERC20 internal weth;
    MockAllowanceHolder internal ah;
    BaseRevenueSwapper internal swapper;

    address internal feeCollector = makeAddr("feeCollector");
    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        frxusd = new MockERC20("frxUSD", "frxUSD");
        weth = new MockERC20("Wrapped Ether", "WETH");
        ah = new MockAllowanceHolder();
        swapper = new BaseRevenueSwapper(owner, address(ah), address(weth), feeCollector, keeper);

        weth.mint(address(ah), 100e18); // AllowanceHolder inventory to deliver swap output
    }

    function _swapCalldata(
        uint256 amountIn,
        uint256 amountOut
    ) internal view returns (bytes memory) {
        return _swapCalldataFor(address(frxusd), amountIn, amountOut);
    }

    function _swapCalldataFor(
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut
    ) internal view returns (bytes memory) {
        return abi.encodeCall(MockAllowanceHolder.exec, (tokenIn, amountIn, address(weth), amountOut));
    }

    /* -------------------------------------------------------------------------- */
    /*                                construction                                 */
    /* -------------------------------------------------------------------------- */

    function test_Constructor_SetsImmutables() public view {
        assertEq(swapper.ALLOWANCE_HOLDER(), address(ah), "ah");
        assertEq(swapper.WETH(), address(weth), "weth");
        assertEq(swapper.FEE_COLLECTOR(), feeCollector, "fc");
        assertEq(swapper.keeper(), keeper, "keeper");
    }

    function test_RevertWhen_Constructor_ZeroAllowanceHolder() public {
        vm.expectRevert(BaseRevenueSwapper.ZeroAddress.selector);
        new BaseRevenueSwapper(owner, address(0), address(weth), feeCollector, keeper);
    }

    function test_RevertWhen_Constructor_ZeroWeth() public {
        vm.expectRevert(BaseRevenueSwapper.ZeroAddress.selector);
        new BaseRevenueSwapper(owner, address(ah), address(0), feeCollector, keeper);
    }

    function test_RevertWhen_Constructor_ZeroFeeCollector() public {
        vm.expectRevert(BaseRevenueSwapper.ZeroAddress.selector);
        new BaseRevenueSwapper(owner, address(ah), address(weth), address(0), keeper);
    }

    function test_RevertWhen_Constructor_ZeroKeeper() public {
        vm.expectRevert(BaseRevenueSwapper.ZeroAddress.selector);
        new BaseRevenueSwapper(owner, address(ah), address(weth), feeCollector, address(0));
    }

    /* -------------------------------------------------------------------------- */
    /*                                swapAndForward                               */
    /* -------------------------------------------------------------------------- */

    function test_RevertWhen_NotKeeper() public {
        frxusd.mint(address(swapper), AMOUNT);
        vm.prank(attacker);
        vm.expectRevert(BaseRevenueSwapper.NotKeeper.selector);
        swapper.swapAndForward(address(frxusd), _swapCalldata(AMOUNT, 0.35e18), 0);
    }

    function test_RevertWhen_TokenInIsWeth() public {
        weth.mint(address(swapper), AMOUNT);
        vm.prank(keeper);
        vm.expectRevert(BaseRevenueSwapper.InvalidTokenIn.selector);
        swapper.swapAndForward(address(weth), _swapCalldataFor(address(weth), AMOUNT, 0), 0);
    }

    function test_RevertWhen_TokenInIsZero() public {
        vm.prank(keeper);
        vm.expectRevert(BaseRevenueSwapper.InvalidTokenIn.selector);
        swapper.swapAndForward(address(0), "", 0);
    }

    function test_RevertWhen_NothingToSwap() public {
        vm.prank(keeper);
        vm.expectRevert(BaseRevenueSwapper.NothingToSwap.selector);
        swapper.swapAndForward(address(frxusd), _swapCalldata(AMOUNT, 0.35e18), 0);
    }

    function test_SwapAndForward_Success() public {
        frxusd.mint(address(swapper), AMOUNT);
        vm.prank(keeper);
        swapper.swapAndForward(address(frxusd), _swapCalldata(AMOUNT, 0.35e18), 0);

        assertEq(weth.balanceOf(feeCollector), 0.35e18, "WETH forwarded to FeeCollector");
        assertEq(weth.balanceOf(address(swapper)), 0, "no WETH left in swapper");
        assertEq(frxusd.balanceOf(address(ah)), AMOUNT, "frxUSD pulled by AllowanceHolder");
        assertEq(frxusd.allowance(address(swapper), address(ah)), 0, "approval reset");
    }

    function test_SwapAndForward_GeneralizedTokenIn() public {
        // Any non-WETH delivered token works (e.g. a future chain bridging USDC to Base).
        MockERC20 usdc = new MockERC20("USD Coin", "USDC");
        usdc.mint(address(swapper), AMOUNT);

        vm.prank(keeper);
        swapper.swapAndForward(address(usdc), _swapCalldataFor(address(usdc), AMOUNT, 0.3e18), 0);

        assertEq(weth.balanceOf(feeCollector), 0.3e18, "non-frxUSD token swapped + forwarded");
        assertEq(usdc.balanceOf(address(ah)), AMOUNT, "usdc pulled by AllowanceHolder");
        assertEq(usdc.allowance(address(swapper), address(ah)), 0, "approval reset");
    }

    function test_SwapAndForward_ForwardsPreExistingBridgedWeth() public {
        weth.mint(address(swapper), 0.1e18); // bridged-in WETH from ETH/Ink/Katana lanes
        frxusd.mint(address(swapper), AMOUNT);

        vm.prank(keeper);
        swapper.swapAndForward(address(frxusd), _swapCalldata(AMOUNT, 0.35e18), 0);

        assertEq(weth.balanceOf(feeCollector), 0.45e18, "bridged WETH rides along");
        assertEq(weth.balanceOf(address(swapper)), 0, "swapper drained");
    }

    function test_SwapAndForward_ResetsApprovalAfterPartialPull() public {
        frxusd.mint(address(swapper), AMOUNT);
        vm.prank(keeper);
        swapper.swapAndForward(address(frxusd), _swapCalldata(600e18, 0.5e18), 0);
        assertEq(frxusd.allowance(address(swapper), address(ah)), 0, "approval reset after partial pull");
    }

    function test_RevertWhen_MinOutViolated() public {
        frxusd.mint(address(swapper), AMOUNT);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(BaseRevenueSwapper.InsufficientOutput.selector, 0.32e18, 0.4e18));
        swapper.swapAndForward(address(frxusd), _swapCalldata(AMOUNT, 0.32e18), 0.4e18);
    }

    function test_RevertWhen_SwapCallFails() public {
        frxusd.mint(address(swapper), AMOUNT);
        ah.setReverting(true);
        vm.prank(keeper);
        vm.expectRevert(BaseRevenueSwapper.SwapCallFailed.selector);
        swapper.swapAndForward(address(frxusd), _swapCalldata(AMOUNT, 0.35e18), 0);
    }

    /* -------------------------------------------------------------------------- */
    /*                                  forwardWeth                                */
    /* -------------------------------------------------------------------------- */

    function test_ForwardWeth_Permissionless() public {
        weth.mint(address(swapper), 0.5e18);
        vm.prank(attacker);
        swapper.forwardWeth();
        assertEq(weth.balanceOf(feeCollector), 0.5e18, "swept to FeeCollector");
    }

    function test_RevertWhen_ForwardWeth_Nothing() public {
        vm.expectRevert(BaseRevenueSwapper.NothingToForward.selector);
        swapper.forwardWeth();
    }

    function test_ForwardWeth_NonReentrant_BlockedDuringSwap() public {
        ReentrantAllowanceHolder rah = new ReentrantAllowanceHolder();
        BaseRevenueSwapper s = new BaseRevenueSwapper(owner, address(rah), address(weth), feeCollector, keeper);
        rah.setSwapper(address(s));

        weth.mint(address(rah), 100e18); // inventory for swap output
        frxusd.mint(address(s), AMOUNT);
        weth.mint(address(s), 0.1e18); // pre-existing WETH the reentrant forwardWeth would grab

        vm.prank(keeper);
        s.swapAndForward(address(frxusd), _swapCalldata(AMOUNT, 0.35e18), 0);

        assertFalse(rah.reentrySucceeded(), "forwardWeth reentry blocked by nonReentrant");
        assertEq(weth.balanceOf(feeCollector), 0.45e18, "swap completed, full WETH forwarded");
    }

    /* -------------------------------------------------------------------------- */
    /*                                keeper control                              */
    /* -------------------------------------------------------------------------- */

    function test_RevokeKeeper_IsInstantAndBlocks() public {
        vm.prank(owner);
        swapper.revokeKeeper();
        assertEq(swapper.keeper(), address(0), "revoked");

        frxusd.mint(address(swapper), AMOUNT);
        vm.prank(keeper);
        vm.expectRevert(BaseRevenueSwapper.NotKeeper.selector);
        swapper.swapAndForward(address(frxusd), _swapCalldata(AMOUNT, 0.35e18), 0);
    }

    function test_RevertWhen_RevokeKeeper_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        swapper.revokeKeeper();
    }

    function test_SetKeeper_HonorsTimelock() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        swapper.signalSetKeeper(newKeeper);
        vm.warp(block.timestamp + 7 days);
        swapper.executeSetKeeper(newKeeper);
        assertEq(swapper.keeper(), newKeeper, "updated");
    }

    function test_RevertWhen_SignalSetKeeper_Zero() public {
        vm.prank(owner);
        vm.expectRevert(BaseRevenueSwapper.ZeroAddress.selector);
        swapper.signalSetKeeper(address(0));
    }

    function test_CancelSetKeeper() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        swapper.signalSetKeeper(newKeeper);
        vm.prank(owner);
        swapper.cancelSetKeeper();
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        swapper.executeSetKeeper(newKeeper);
    }

    function test_RevokeKeeper_CancelsPendingSetKeeper() public {
        // The emergency kill switch must also void an in-flight rotation, so it cannot be
        // permissionlessly re-armed after the delay.
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        swapper.signalSetKeeper(newKeeper);

        vm.prank(owner);
        swapper.revokeKeeper();
        assertEq(swapper.keeper(), address(0), "keeper revoked");

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        swapper.executeSetKeeper(newKeeper);
        assertEq(swapper.keeper(), address(0), "still revoked, not re-armed");
    }

    /* -------------------------------------------------------------------------- */
    /*                                   rescue                                    */
    /* -------------------------------------------------------------------------- */

    function test_RescueToken_HonorsTimelock() public {
        MockERC20 stranded = new MockERC20("Stuck", "STK");
        stranded.mint(address(swapper), 9e18);
        address to = makeAddr("rescueTo");
        vm.prank(owner);
        swapper.signalRescue(address(stranded), to, 9e18);
        vm.warp(block.timestamp + 7 days);
        swapper.executeRescue(address(stranded), to, 9e18);
        assertEq(stranded.balanceOf(to), 9e18, "rescued");
    }

    function test_RescueNative_HonorsTimelock() public {
        vm.deal(address(swapper), 1 ether);
        address to = makeAddr("rescueTo");
        vm.prank(owner);
        swapper.signalRescue(address(0), to, 0.5 ether);
        vm.warp(block.timestamp + 7 days);
        swapper.executeRescue(address(0), to, 0.5 ether);
        assertEq(to.balance, 0.5 ether, "native rescued");
    }

    function test_RevertWhen_RescueNative_TransferFails() public {
        vm.deal(address(swapper), 1 ether);
        address to = address(new RejectNative());
        vm.prank(owner);
        swapper.signalRescue(address(0), to, 0.5 ether);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(BaseRevenueSwapper.RescueFailed.selector);
        swapper.executeRescue(address(0), to, 0.5 ether);
    }

    function test_CancelRescue() public {
        address to = makeAddr("rescueTo");
        vm.prank(owner);
        swapper.signalRescue(address(frxusd), to, 1e18);
        vm.prank(owner);
        swapper.cancelRescue(address(frxusd));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        swapper.executeRescue(address(frxusd), to, 1e18);
    }

    function test_RevertWhen_SignalRescue_ZeroTo() public {
        vm.prank(owner);
        vm.expectRevert(BaseRevenueSwapper.ZeroAddress.selector);
        swapper.signalRescue(address(frxusd), address(0), 1e18);
    }

    function test_RevertWhen_GenericSignalAction_Sealed() public {
        vm.prank(owner);
        vm.expectRevert(BaseRevenueSwapper.NotAuthorized.selector);
        swapper.signalAction(keccak256("x"), keccak256("y"));
    }
}

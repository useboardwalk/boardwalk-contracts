// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RevenueBridger} from "src/crosschain/RevenueBridger.sol";
import {ILiFi} from "src/interfaces/ILiFi.sol";
import {Timelocked} from "src/base/Timelocked.sol";

/// @dev Minimal mintable ERC20.
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

/// @dev Mock LiFi Diamond. Its `fallback` simulates a facet pulling the bridger's approved raise
///      token (the deposit), with configurable behaviors to exercise the bridger's approve/reset/delta checks.
///      Payable: accepts the forwarded native fee and can refund a configurable excess to the caller
///      (modeling a GMP/Glacis over-quote refund).
contract MockLiFiDiamond {
    enum Mode {
        PULL_FULL, // pull the full approved amount (delta == amount)
        PULL_HALF, // pull half (delta < amount) — exercises the approval reset
        REFUND, // pull full, then refund to the decoded AcrossV4Data.refundAddress (forced expiry)
        REVERTING, // revert (BridgeCallFailed)
        DONATE // transfer tokens TO the caller without pulling (balanceAfter > before)
    }

    address public immutable RAISE_TOKEN;
    Mode public mode = Mode.PULL_FULL;
    uint256 public nativeRefund; // native to send back to the caller (excess-fee refund)

    constructor(
        address raiseToken
    ) {
        RAISE_TOKEN = raiseToken;
    }

    function setMode(
        Mode m
    ) external {
        mode = m;
    }

    function setNativeRefund(
        uint256 v
    ) external {
        nativeRefund = v;
    }

    fallback() external payable {
        if (mode == Mode.REVERTING) revert("diamond: forced revert");

        if (nativeRefund > 0) {
            (bool s,) = msg.sender.call{value: nativeRefund}("");
            require(s, "diamond: native refund failed");
        }

        if (mode == Mode.DONATE) {
            // Simulate the diamond pushing tokens to the bridger (net balance gain).
            IERC20(RAISE_TOKEN).transfer(msg.sender, IERC20(RAISE_TOKEN).balanceOf(address(this)));
            return;
        }

        uint256 allowance = IERC20(RAISE_TOKEN).allowance(msg.sender, address(this));
        uint256 toPull = mode == Mode.PULL_HALF ? allowance / 2 : allowance;
        IERC20(RAISE_TOKEN).transferFrom(msg.sender, address(this), toPull);

        if (mode == Mode.REFUND) {
            (, ILiFi.AcrossV4Data memory acrossData) = abi.decode(msg.data[4:], (ILiFi.BridgeData, ILiFi.AcrossV4Data));
            address refundTo = address(uint160(uint256(acrossData.refundAddress)));
            IERC20(RAISE_TOKEN).transfer(refundTo, toPull);
        }
    }
}

/// @dev Contract keeper with no `receive()` — triggers `NativeRefundFailed` when the bridger tries
///      to refund unconsumed native to it.
contract NoReceiveKeeper {
    function bridge(
        RevenueBridger b,
        uint256 amount,
        bytes calldata cd
    ) external payable {
        b.bridgeToEthereum{value: msg.value}(amount, cd);
    }
}

/// @dev Rejects native; used to exercise the `RescueFailed` path.
contract RejectNative {}

contract RevenueBridgerTest is Test {
    bytes4 internal constant ACROSS_V4_SELECTOR = 0xa1f1ce43;
    bytes4 internal constant SYMBIOSIS_SELECTOR = 0x6e067161;
    bytes4 internal constant GLACIS_SELECTOR = 0x9c4b6dd9;
    uint256 internal constant MAX_FEE_BPS = 30;
    uint256 internal constant AMOUNT = 100e18;
    uint256 internal constant ETHEREUM_CHAIN_ID = 1;

    MockERC20 internal raiseToken;
    address internal ethereumWeth = makeAddr("ethereumWeth");
    address internal ethereumDestination = makeAddr("ethereumDestination");
    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");

    MockLiFiDiamond internal diamond;
    RevenueBridger internal bridgerPure;
    RevenueBridger internal bridgerComposed;
    RevenueBridger internal bridgerGlacis;

    function setUp() public {
        raiseToken = new MockERC20("Raise", "RAISE");
        diamond = new MockLiFiDiamond(address(raiseToken));

        bridgerPure = _newBridger(false, ACROSS_V4_SELECTOR);
        bridgerComposed = _newBridger(true, SYMBIOSIS_SELECTOR);
        bridgerGlacis = _newBridger(true, GLACIS_SELECTOR);

        raiseToken.mint(address(bridgerPure), AMOUNT);
        raiseToken.mint(address(bridgerComposed), AMOUNT);
        raiseToken.mint(address(bridgerGlacis), AMOUNT);
    }

    function _newBridger(
        bool hasSourceSwaps,
        bytes4 selector
    ) internal returns (RevenueBridger) {
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = selector;
        return new RevenueBridger(
            owner,
            address(diamond),
            address(raiseToken),
            ethereumDestination,
            ethereumWeth,
            keeper,
            hasSourceSwaps,
            MAX_FEE_BPS,
            sel
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                                 construction                                */
    /* -------------------------------------------------------------------------- */

    function test_Constructor_SetsImmutablesAndAllowlist() public view {
        assertEq(bridgerPure.DIAMOND(), address(diamond), "diamond");
        assertEq(bridgerPure.RAISE_TOKEN(), address(raiseToken), "raise");
        assertEq(bridgerPure.ETHEREUM_DESTINATION(), ethereumDestination, "dest");
        assertEq(bridgerPure.ETHEREUM_WETH(), ethereumWeth, "weth");
        assertEq(bridgerPure.MAX_FEE_BPS(), MAX_FEE_BPS, "maxfee");
        assertEq(bridgerPure.keeper(), keeper, "keeper");
        assertFalse(bridgerPure.HAS_SOURCE_SWAPS(), "pure has no source swaps");
        assertTrue(bridgerComposed.HAS_SOURCE_SWAPS(), "composed has source swaps");
        assertTrue(bridgerPure.allowedSelectors(ACROSS_V4_SELECTOR), "pure selector seeded");
        assertTrue(bridgerComposed.allowedSelectors(SYMBIOSIS_SELECTOR), "composed selector seeded");
        assertTrue(bridgerGlacis.allowedSelectors(GLACIS_SELECTOR), "glacis selector seeded");
    }

    function test_RevertWhen_Constructor_MaxFeeBpsOutOfRange() public {
        bytes4[] memory sel = new bytes4[](0);
        vm.expectRevert(RevenueBridger.InvalidConfig.selector);
        new RevenueBridger(
            owner, address(diamond), address(raiseToken), ethereumDestination, ethereumWeth, keeper, false, 10_000, sel
        );
    }

    function test_RevertWhen_Constructor_ZeroDiamond() public {
        bytes4[] memory sel = new bytes4[](0);
        vm.expectRevert(RevenueBridger.ZeroAddress.selector);
        new RevenueBridger(
            owner, address(0), address(raiseToken), ethereumDestination, ethereumWeth, keeper, false, MAX_FEE_BPS, sel
        );
    }

    function test_RevertWhen_Constructor_ZeroRaiseToken() public {
        vm.expectRevert(RevenueBridger.ZeroAddress.selector);
        new RevenueBridger(
            owner,
            address(diamond),
            address(0),
            ethereumDestination,
            ethereumWeth,
            keeper,
            false,
            MAX_FEE_BPS,
            _sel(ACROSS_V4_SELECTOR)
        );
    }

    function test_RevertWhen_Constructor_ZeroEthereumDestination() public {
        vm.expectRevert(RevenueBridger.ZeroAddress.selector);
        new RevenueBridger(
            owner,
            address(diamond),
            address(raiseToken),
            address(0),
            ethereumWeth,
            keeper,
            false,
            MAX_FEE_BPS,
            _sel(ACROSS_V4_SELECTOR)
        );
    }

    function test_RevertWhen_Constructor_ZeroEthereumWeth() public {
        vm.expectRevert(RevenueBridger.ZeroAddress.selector);
        new RevenueBridger(
            owner,
            address(diamond),
            address(raiseToken),
            ethereumDestination,
            address(0),
            keeper,
            false,
            MAX_FEE_BPS,
            _sel(ACROSS_V4_SELECTOR)
        );
    }

    function test_RevertWhen_Constructor_ZeroKeeper() public {
        vm.expectRevert(RevenueBridger.ZeroAddress.selector);
        new RevenueBridger(
            owner,
            address(diamond),
            address(raiseToken),
            ethereumDestination,
            ethereumWeth,
            address(0),
            false,
            MAX_FEE_BPS,
            _sel(ACROSS_V4_SELECTOR)
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                              access / selector                             */
    /* -------------------------------------------------------------------------- */

    function test_RevertWhen_NotKeeper() public {
        vm.prank(attacker);
        vm.expectRevert(RevenueBridger.NotKeeper.selector);
        bridgerPure.bridgeToEthereum(AMOUNT, _buildPure(AMOUNT));
    }

    function test_RevertWhen_ZeroAmount() public {
        vm.prank(keeper);
        vm.expectRevert(RevenueBridger.ZeroAmount.selector);
        bridgerPure.bridgeToEthereum(0, _buildPure(AMOUNT));
    }

    function test_RevertWhen_CalldataTooShort() public {
        vm.prank(keeper);
        vm.expectRevert(RevenueBridger.CalldataTooShort.selector);
        bridgerPure.bridgeToEthereum(AMOUNT, hex"a1f1ce");
    }

    function test_RevertWhen_SelectorNotAllowed() public {
        bytes memory cd = abi.encodeWithSelector(bytes4(0xdeadbeef), _pureBridgeData(AMOUNT), _pureAcrossData(AMOUNT));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RevenueBridger.SelectorNotAllowed.selector, bytes4(0xdeadbeef)));
        bridgerPure.bridgeToEthereum(AMOUNT, cd);
    }

    function test_RevertWhen_SymbiosisSelectorOnPureLane() public {
        bytes memory cd = abi.encodeWithSelector(SYMBIOSIS_SELECTOR, _pureBridgeData(AMOUNT), _pureAcrossData(AMOUNT));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RevenueBridger.SelectorNotAllowed.selector, SYMBIOSIS_SELECTOR));
        bridgerPure.bridgeToEthereum(AMOUNT, cd);
    }

    /* -------------------------------------------------------------------------- */
    /*                         pinning — pure Across V4 lane                       */
    /* -------------------------------------------------------------------------- */

    function test_RevertWhen_Pure_InvalidReceiver() public {
        ILiFi.BridgeData memory bd = _pureBridgeData(AMOUNT);
        bd.receiver = address(0xBAD);
        _expectPureRevert(bd, _pureAcrossData(AMOUNT), RevenueBridger.InvalidReceiver.selector);
    }

    function test_RevertWhen_Pure_InvalidDestinationChain() public {
        ILiFi.BridgeData memory bd = _pureBridgeData(AMOUNT);
        bd.destinationChainId = 8453;
        _expectPureRevert(bd, _pureAcrossData(AMOUNT), RevenueBridger.InvalidDestinationChain.selector);
    }

    function test_RevertWhen_Pure_DestinationCall() public {
        ILiFi.BridgeData memory bd = _pureBridgeData(AMOUNT);
        bd.hasDestinationCall = true;
        _expectPureRevert(bd, _pureAcrossData(AMOUNT), RevenueBridger.DestinationCallNotAllowed.selector);
    }

    function test_RevertWhen_Pure_SourceSwapsMismatch() public {
        // A composed-shape flag on a pure lane must self-revert (the new hasSourceSwaps pin).
        ILiFi.BridgeData memory bd = _pureBridgeData(AMOUNT);
        bd.hasSourceSwaps = true;
        _expectPureRevert(bd, _pureAcrossData(AMOUNT), RevenueBridger.InvalidSourceSwaps.selector);
    }

    function test_RevertWhen_Pure_BridgeDataSendingAsset() public {
        ILiFi.BridgeData memory bd = _pureBridgeData(AMOUNT);
        bd.sendingAssetId = address(0xBAD);
        _expectPureRevert(bd, _pureAcrossData(AMOUNT), RevenueBridger.InvalidSendingAsset.selector);
    }

    function test_RevertWhen_Pure_MinAmount() public {
        ILiFi.BridgeData memory bd = _pureBridgeData(AMOUNT);
        bd.minAmount = AMOUNT - 1;
        _expectPureRevert(bd, _pureAcrossData(AMOUNT), RevenueBridger.InvalidMinAmount.selector);
    }

    function test_RevertWhen_Pure_RefundAddressNotBridger() public {
        ILiFi.AcrossV4Data memory ad = _pureAcrossData(AMOUNT);
        ad.refundAddress = _b32(attacker);
        _expectPureRevert(_pureBridgeData(AMOUNT), ad, RevenueBridger.InvalidRefundAddress.selector);
    }

    function test_RevertWhen_Pure_AcrossSendingAsset() public {
        ILiFi.AcrossV4Data memory ad = _pureAcrossData(AMOUNT);
        ad.sendingAssetId = _b32(address(0xBAD));
        _expectPureRevert(_pureBridgeData(AMOUNT), ad, RevenueBridger.InvalidSendingAsset.selector);
    }

    function test_RevertWhen_Pure_ReceivingAsset() public {
        ILiFi.AcrossV4Data memory ad = _pureAcrossData(AMOUNT);
        ad.receivingAssetId = _b32(address(0xBAD));
        _expectPureRevert(_pureBridgeData(AMOUNT), ad, RevenueBridger.InvalidReceivingAsset.selector);
    }

    function test_RevertWhen_Pure_OutputAmountBelowFloor() public {
        ILiFi.AcrossV4Data memory ad = _pureAcrossData(AMOUNT);
        ad.outputAmount = (AMOUNT * (10_000 - MAX_FEE_BPS) / 10_000) - 1;
        _expectPureRevert(_pureBridgeData(AMOUNT), ad, RevenueBridger.InsufficientOutputAmount.selector);
    }

    function test_RevertWhen_Pure_ReceiverAddress() public {
        ILiFi.AcrossV4Data memory ad = _pureAcrossData(AMOUNT);
        ad.receiverAddress = _b32(attacker);
        _expectPureRevert(_pureBridgeData(AMOUNT), ad, RevenueBridger.InvalidReceiverAddress.selector);
    }

    /* -------------------------------------------------------------------------- */
    /*                          pure happy path + forced expiry                   */
    /* -------------------------------------------------------------------------- */

    function test_BridgeToEthereum_Pure_Success() public {
        uint256 before = raiseToken.balanceOf(address(bridgerPure));
        vm.prank(keeper);
        bridgerPure.bridgeToEthereum(AMOUNT, _buildPure(AMOUNT));

        assertEq(raiseToken.balanceOf(address(bridgerPure)), before - AMOUNT, "full amount deposited");
        assertEq(raiseToken.balanceOf(address(diamond)), AMOUNT, "diamond received deposit");
        assertEq(raiseToken.allowance(address(bridgerPure), address(diamond)), 0, "approval reset");
    }

    function test_BridgeToEthereum_Pure_PartialPullResetsApproval() public {
        diamond.setMode(MockLiFiDiamond.Mode.PULL_HALF);
        vm.prank(keeper);
        bridgerPure.bridgeToEthereum(AMOUNT, _buildPure(AMOUNT));

        assertEq(raiseToken.balanceOf(address(diamond)), AMOUNT / 2, "half deposited");
        assertEq(raiseToken.allowance(address(bridgerPure), address(diamond)), 0, "approval reset after partial pull");
    }

    function test_ForcedExpiry_RefundsToBridgerNotKeeper() public {
        diamond.setMode(MockLiFiDiamond.Mode.REFUND);
        uint256 before = raiseToken.balanceOf(address(bridgerPure));

        vm.prank(keeper);
        bridgerPure.bridgeToEthereum(AMOUNT, _buildPure(AMOUNT));

        assertEq(raiseToken.balanceOf(address(bridgerPure)), before, "refund returned to bridger");
        assertEq(raiseToken.balanceOf(keeper), 0, "keeper received nothing");
    }

    function test_RevertWhen_BridgeCallFails() public {
        diamond.setMode(MockLiFiDiamond.Mode.REVERTING);
        vm.prank(keeper);
        vm.expectRevert(RevenueBridger.BridgeCallFailed.selector);
        bridgerPure.bridgeToEthereum(AMOUNT, _buildPure(AMOUNT));
    }

    function test_RevertWhen_BalanceDeltaExceeded() public {
        diamond.setMode(MockLiFiDiamond.Mode.DONATE);
        raiseToken.mint(address(diamond), 5e18);
        vm.prank(keeper);
        vm.expectRevert(RevenueBridger.BalanceDeltaExceeded.selector);
        bridgerPure.bridgeToEthereum(AMOUNT, _buildPure(AMOUNT));
    }

    /* -------------------------------------------------------------------------- */
    /*                            native fee (payable)                            */
    /* -------------------------------------------------------------------------- */

    function test_Receive_AcceptsNative() public {
        (bool ok,) = address(bridgerPure).call{value: 1 ether}("");
        assertTrue(ok, "receive accepts native");
        assertEq(address(bridgerPure).balance, 1 ether, "native held");
    }

    function test_BridgeToEthereum_ConsumesAllNative_NoRefund() public {
        vm.deal(keeper, 1 ether);
        uint256 keeperBefore = keeper.balance;

        vm.prank(keeper);
        bridgerPure.bridgeToEthereum{value: 0.2 ether}(AMOUNT, _buildPure(AMOUNT));

        // Diamond kept the full fee; nothing refunded; the bridger holds no native.
        assertEq(keeper.balance, keeperBefore - 0.2 ether, "keeper paid the full fee");
        assertEq(address(bridgerPure).balance, 0, "no native stuck in bridger");
        assertEq(address(diamond).balance, 0.2 ether, "diamond received the fee");
    }

    function test_BridgeToEthereum_RefundsExcessNativeToKeeper_PreservesPreExisting() public {
        // Pre-existing native in the bridger must not be refunded to the keeper.
        vm.deal(address(bridgerPure), 1 ether);
        diamond.setNativeRefund(0.05 ether); // diamond over-quote refund to the bridger

        vm.deal(keeper, 1 ether);
        uint256 keeperBefore = keeper.balance;

        vm.prank(keeper);
        bridgerPure.bridgeToEthereum{value: 0.2 ether}(AMOUNT, _buildPure(AMOUNT));

        // Keeper paid 0.2 then got 0.05 back; the pre-existing 1 ether stays for rescue.
        assertEq(keeper.balance, keeperBefore - 0.2 ether + 0.05 ether, "excess refunded to keeper");
        assertEq(address(bridgerPure).balance, 1 ether, "pre-existing native untouched");
    }

    function test_RevertWhen_NativeRefundFails() public {
        NoReceiveKeeper ck = new NoReceiveKeeper();
        RevenueBridger b = new RevenueBridger(
            owner,
            address(diamond),
            address(raiseToken),
            ethereumDestination,
            ethereumWeth,
            address(ck),
            false,
            MAX_FEE_BPS,
            _sel(ACROSS_V4_SELECTOR)
        );
        raiseToken.mint(address(b), AMOUNT);
        diamond.setNativeRefund(0.05 ether); // forces a refund the contract-keeper cannot receive

        vm.deal(address(ck), 1 ether);
        vm.expectRevert(RevenueBridger.NativeRefundFailed.selector);
        ck.bridge{value: 0.2 ether}(b, AMOUNT, _buildPureFor(address(b), AMOUNT));
    }

    /* -------------------------------------------------------------------------- */
    /*                       pinning — composed Symbiosis lane                     */
    /* -------------------------------------------------------------------------- */

    function test_BridgeToEthereum_Composed_BaselinePasses() public {
        uint256 before = raiseToken.balanceOf(address(bridgerComposed));
        vm.prank(keeper);
        bridgerComposed.bridgeToEthereum(AMOUNT, _buildComposed(SYMBIOSIS_SELECTOR, AMOUNT));
        assertEq(raiseToken.balanceOf(address(bridgerComposed)), before - AMOUNT, "deposited");
        assertEq(raiseToken.allowance(address(bridgerComposed), address(diamond)), 0, "approval reset");
    }

    function test_RevertWhen_Composed_SourceSwapsMismatch() public {
        // A pure-shape flag on a composed lane must self-revert.
        ILiFi.BridgeData memory bd = _composedBridgeData();
        bd.hasSourceSwaps = false;
        bytes memory cd = abi.encodeWithSelector(SYMBIOSIS_SELECTOR, bd, _composedSwaps(AMOUNT));
        vm.prank(keeper);
        vm.expectRevert(RevenueBridger.InvalidSourceSwaps.selector);
        bridgerComposed.bridgeToEthereum(AMOUNT, cd);
    }

    function test_RevertWhen_Composed_InvalidReceiver() public {
        ILiFi.BridgeData memory bd = _composedBridgeData();
        bd.receiver = address(0xBAD);
        bytes memory cd = abi.encodeWithSelector(SYMBIOSIS_SELECTOR, bd, _composedSwaps(AMOUNT));
        vm.prank(keeper);
        vm.expectRevert(RevenueBridger.InvalidReceiver.selector);
        bridgerComposed.bridgeToEthereum(AMOUNT, cd);
    }

    function test_RevertWhen_Composed_LegSendingAsset() public {
        ILiFi.SwapData[] memory swaps = _composedSwaps(AMOUNT);
        swaps[0].sendingAssetId = address(0xBAD);
        bytes memory cd = abi.encodeWithSelector(SYMBIOSIS_SELECTOR, _composedBridgeData(), swaps);
        vm.prank(keeper);
        vm.expectRevert(RevenueBridger.InvalidSendingAsset.selector);
        bridgerComposed.bridgeToEthereum(AMOUNT, cd);
    }

    function test_RevertWhen_Composed_DepositSumMismatch() public {
        ILiFi.SwapData[] memory swaps = new ILiFi.SwapData[](2);
        swaps[0] = _depositLeg(AMOUNT / 2);
        swaps[1] = _depositLeg(AMOUNT / 2 - 1); // sum != AMOUNT
        bytes memory cd = abi.encodeWithSelector(SYMBIOSIS_SELECTOR, _composedBridgeData(), swaps);
        vm.prank(keeper);
        vm.expectRevert(RevenueBridger.DepositSumMismatch.selector);
        bridgerComposed.bridgeToEthereum(AMOUNT, cd);
    }

    function test_Composed_NonDepositLegsIgnored() public {
        ILiFi.SwapData[] memory swaps = new ILiFi.SwapData[](2);
        swaps[0] = _depositLeg(AMOUNT);
        swaps[1] = ILiFi.SwapData({
            callTo: address(0xCA11),
            approveTo: address(0xCA11),
            sendingAssetId: address(0xBAD),
            receivingAssetId: ethereumWeth,
            fromAmount: 12345,
            callData: "",
            requiresDeposit: false
        });
        bytes memory cd = abi.encodeWithSelector(SYMBIOSIS_SELECTOR, _composedBridgeData(), swaps);
        vm.prank(keeper);
        bridgerComposed.bridgeToEthereum(AMOUNT, cd);
        assertEq(raiseToken.balanceOf(address(diamond)), AMOUNT, "deposited despite foreign non-deposit leg");
    }

    /* -------------------------------------------------------------------------- */
    /*            composed Glacis-shape lane (native fee) — same contract         */
    /* -------------------------------------------------------------------------- */

    function test_BridgeToEthereum_Glacis_ComposedWithNativeFee() public {
        // No current lane is composed; the shape is retained for future non-WETH raise tokens.
        // Same generic bridger, composed shape, native GMP fee as msg.value.
        diamond.setNativeRefund(0.01 ether); // simulate a small over-quote refund
        vm.deal(keeper, 1 ether);
        uint256 keeperBefore = keeper.balance;
        uint256 before = raiseToken.balanceOf(address(bridgerGlacis));

        vm.prank(keeper);
        bridgerGlacis.bridgeToEthereum{value: 0.3 ether}(AMOUNT, _buildComposed(GLACIS_SELECTOR, AMOUNT));

        assertEq(raiseToken.balanceOf(address(bridgerGlacis)), before - AMOUNT, "deposited");
        assertEq(raiseToken.allowance(address(bridgerGlacis), address(diamond)), 0, "approval reset");
        assertEq(keeper.balance, keeperBefore - 0.3 ether + 0.01 ether, "excess GMP fee refunded");
        assertEq(address(bridgerGlacis).balance, 0, "no native stuck");
    }

    /* -------------------------------------------------------------------------- */
    /*                              keeper control                                */
    /* -------------------------------------------------------------------------- */

    function test_RevokeKeeper_IsInstantAndBlocksBridging() public {
        vm.prank(owner);
        bridgerPure.revokeKeeper();
        assertEq(bridgerPure.keeper(), address(0), "keeper zeroed");

        vm.prank(keeper);
        vm.expectRevert(RevenueBridger.NotKeeper.selector);
        bridgerPure.bridgeToEthereum(AMOUNT, _buildPure(AMOUNT));
    }

    function test_RevertWhen_RevokeKeeper_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        bridgerPure.revokeKeeper();
    }

    function test_SetKeeper_HonorsTimelock() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        bridgerPure.signalSetKeeper(newKeeper);

        vm.expectRevert();
        bridgerPure.executeSetKeeper(newKeeper); // too early

        vm.warp(block.timestamp + 7 days);
        bridgerPure.executeSetKeeper(newKeeper); // permissionless after delay
        assertEq(bridgerPure.keeper(), newKeeper, "keeper updated");

        vm.prank(newKeeper);
        bridgerPure.bridgeToEthereum(AMOUNT, _buildPure(AMOUNT));
    }

    function test_RevertWhen_SignalSetKeeper_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        bridgerPure.signalSetKeeper(attacker);
    }

    function test_RevertWhen_SignalSetKeeper_Zero() public {
        vm.prank(owner);
        vm.expectRevert(RevenueBridger.ZeroAddress.selector);
        bridgerPure.signalSetKeeper(address(0));
    }

    function test_CancelSetKeeper() public {
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        bridgerPure.signalSetKeeper(newKeeper);
        vm.prank(owner);
        bridgerPure.cancelSetKeeper();
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        bridgerPure.executeSetKeeper(newKeeper);
    }

    function test_RevokeKeeper_CancelsPendingSetKeeper() public {
        // The emergency kill switch must also void an in-flight rotation, so it cannot be
        // permissionlessly re-armed after the delay.
        address newKeeper = makeAddr("newKeeper");
        vm.prank(owner);
        bridgerPure.signalSetKeeper(newKeeper);

        vm.prank(owner);
        bridgerPure.revokeKeeper();
        assertEq(bridgerPure.keeper(), address(0), "keeper revoked");

        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        bridgerPure.executeSetKeeper(newKeeper);
        assertEq(bridgerPure.keeper(), address(0), "still revoked, not re-armed");
    }

    /* -------------------------------------------------------------------------- */
    /*                          selector + rescue timelocks                       */
    /* -------------------------------------------------------------------------- */

    function test_SetSelector_AddHonorsTimelock() public {
        bytes4 newSel = 0x12345678;
        vm.prank(owner);
        bridgerPure.signalSetSelector(newSel, true);
        vm.warp(block.timestamp + 7 days);
        bridgerPure.executeSetSelector(newSel, true);
        assertTrue(bridgerPure.allowedSelectors(newSel), "added");
    }

    function test_SetSelector_RemoveBlocksBridging() public {
        vm.prank(owner);
        bridgerPure.signalSetSelector(ACROSS_V4_SELECTOR, false);
        vm.warp(block.timestamp + 7 days);
        bridgerPure.executeSetSelector(ACROSS_V4_SELECTOR, false);
        assertFalse(bridgerPure.allowedSelectors(ACROSS_V4_SELECTOR), "removed");

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RevenueBridger.SelectorNotAllowed.selector, ACROSS_V4_SELECTOR));
        bridgerPure.bridgeToEthereum(AMOUNT, _buildPure(AMOUNT));
    }

    function test_CancelSetSelector() public {
        bytes4 newSel = 0x12345678;
        vm.prank(owner);
        bridgerPure.signalSetSelector(newSel, true);
        vm.prank(owner);
        bridgerPure.cancelSetSelector(newSel);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        bridgerPure.executeSetSelector(newSel, true);
    }

    function test_RescueToken_HonorsTimelock() public {
        MockERC20 stranded = new MockERC20("Stuck", "STK");
        stranded.mint(address(bridgerPure), 5e18);
        address to = makeAddr("rescueTo");

        vm.prank(owner);
        bridgerPure.signalRescue(address(stranded), to, 5e18);
        vm.warp(block.timestamp + 7 days);
        bridgerPure.executeRescue(address(stranded), to, 5e18);
        assertEq(stranded.balanceOf(to), 5e18, "rescued");
    }

    function test_RescueNative_HonorsTimelock() public {
        vm.deal(address(bridgerPure), 1 ether);
        address to = makeAddr("rescueTo");
        vm.prank(owner);
        bridgerPure.signalRescue(address(0), to, 0.4 ether);
        vm.warp(block.timestamp + 7 days);
        bridgerPure.executeRescue(address(0), to, 0.4 ether);
        assertEq(to.balance, 0.4 ether, "native rescued");
    }

    function test_RevertWhen_RescueNative_TransferFails() public {
        vm.deal(address(bridgerPure), 1 ether);
        address to = address(new RejectNative());
        vm.prank(owner);
        bridgerPure.signalRescue(address(0), to, 0.4 ether);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(RevenueBridger.RescueFailed.selector);
        bridgerPure.executeRescue(address(0), to, 0.4 ether);
    }

    function test_CancelRescue() public {
        address to = makeAddr("rescueTo");
        vm.prank(owner);
        bridgerPure.signalRescue(address(raiseToken), to, 1e18);
        vm.prank(owner);
        bridgerPure.cancelRescue(address(raiseToken));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert();
        bridgerPure.executeRescue(address(raiseToken), to, 1e18);
    }

    function test_RevertWhen_SignalRescue_ZeroTo() public {
        vm.prank(owner);
        vm.expectRevert(RevenueBridger.ZeroAddress.selector);
        bridgerPure.signalRescue(address(raiseToken), address(0), 1e18);
    }

    function test_RevertWhen_GenericSignalAction_Sealed() public {
        vm.prank(owner);
        vm.expectRevert(RevenueBridger.NotAuthorized.selector);
        bridgerPure.signalAction(keccak256("x"), keccak256("y"));
    }

    /* -------------------------------------------------------------------------- */
    /*                                  helpers                                    */
    /* -------------------------------------------------------------------------- */

    function _sel(
        bytes4 s
    ) internal pure returns (bytes4[] memory sel) {
        sel = new bytes4[](1);
        sel[0] = s;
    }

    function _b32(
        address a
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _pureBridgeData(
        uint256 amount
    ) internal view returns (ILiFi.BridgeData memory) {
        return ILiFi.BridgeData({
            transactionId: bytes32(uint256(1)),
            bridge: "across",
            integrator: "boardwalk",
            referrer: address(0),
            sendingAssetId: address(raiseToken),
            receiver: ethereumDestination,
            minAmount: amount,
            destinationChainId: ETHEREUM_CHAIN_ID,
            hasSourceSwaps: false,
            hasDestinationCall: false
        });
    }

    function _pureAcrossDataFor(
        address bridger,
        uint256 amount
    ) internal view returns (ILiFi.AcrossV4Data memory) {
        return ILiFi.AcrossV4Data({
            receiverAddress: _b32(ethereumDestination),
            refundAddress: _b32(bridger),
            sendingAssetId: _b32(address(raiseToken)),
            receivingAssetId: _b32(ethereumWeth),
            outputAmount: amount * (10_000 - MAX_FEE_BPS) / 10_000,
            outputAmountMultiplier: 0,
            exclusiveRelayer: bytes32(0),
            quoteTimestamp: 0,
            fillDeadline: 0,
            exclusivityParameter: 0,
            message: ""
        });
    }

    function _pureAcrossData(
        uint256 amount
    ) internal view returns (ILiFi.AcrossV4Data memory) {
        return _pureAcrossDataFor(address(bridgerPure), amount);
    }

    function _buildPureFor(
        address bridger,
        uint256 amount
    ) internal view returns (bytes memory) {
        return abi.encodeWithSelector(ACROSS_V4_SELECTOR, _pureBridgeData(amount), _pureAcrossDataFor(bridger, amount));
    }

    function _buildPure(
        uint256 amount
    ) internal view returns (bytes memory) {
        return _buildPureFor(address(bridgerPure), amount);
    }

    function _expectPureRevert(
        ILiFi.BridgeData memory bd,
        ILiFi.AcrossV4Data memory ad,
        bytes4 err
    ) internal {
        bytes memory cd = abi.encodeWithSelector(ACROSS_V4_SELECTOR, bd, ad);
        vm.prank(keeper);
        vm.expectRevert(err);
        bridgerPure.bridgeToEthereum(AMOUNT, cd);
    }

    function _composedBridgeData() internal view returns (ILiFi.BridgeData memory) {
        return ILiFi.BridgeData({
            transactionId: bytes32(uint256(2)),
            bridge: "symbiosis",
            integrator: "boardwalk",
            referrer: address(0),
            sendingAssetId: address(0xDEAD), // post-swap asset — not pinned
            receiver: ethereumDestination,
            minAmount: 1, // post-swap amount — not pinned
            destinationChainId: ETHEREUM_CHAIN_ID,
            hasSourceSwaps: true,
            hasDestinationCall: false
        });
    }

    function _depositLeg(
        uint256 fromAmount
    ) internal view returns (ILiFi.SwapData memory) {
        return ILiFi.SwapData({
            callTo: address(0xCA11),
            approveTo: address(0xCA11),
            sendingAssetId: address(raiseToken),
            receivingAssetId: ethereumWeth,
            fromAmount: fromAmount,
            callData: "",
            requiresDeposit: true
        });
    }

    function _composedSwaps(
        uint256 amount
    ) internal view returns (ILiFi.SwapData[] memory swaps) {
        swaps = new ILiFi.SwapData[](1);
        swaps[0] = _depositLeg(amount);
    }

    function _buildComposed(
        bytes4 selector,
        uint256 amount
    ) internal view returns (bytes memory) {
        return abi.encodeWithSelector(selector, _composedBridgeData(), _composedSwaps(amount));
    }
}

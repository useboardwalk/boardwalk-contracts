// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RevenueBridger} from "src/crosschain/RevenueBridger.sol";
import {BaseRevenueSwapper} from "src/crosschain/BaseRevenueSwapper.sol";
import {ILiFi} from "src/interfaces/ILiFi.sol";
import {CrossChainConfig} from "script/CrossChainConfig.sol";

/// @title CrossChainBridgingForkTest
/// @notice Per-lane mainnet fork tests against the real LiFi Diamonds, Across SpokePools, and the
///         0x AllowanceHolder. One generic `RevenueBridger` serves every non-Base lane.
/// @dev    Each test is env-gated and self-skips unless its `<CHAIN>_RPC_URL` is set. The ETH/Ink
///         Across lanes construct pinned calldata in-test (so `refundAddress == bridger`, which a
///         pre-captured fixture cannot know). Katana Symbiosis, Fraxtal Glacis, and the Base 0x swap
///         need keeper/aggregator calldata that cannot be built on-chain, so they consume env
///         fixtures and skip when absent. Fraxtal/Glacis additionally attaches a native (FRAX) fee.
///
///         Examples:
///           ETH_RPC_URL=https://eth.llamarpc.com forge test --match-contract CrossChainBridgingFork -vvv
///           FRAXTAL_RPC_URL=... FRAXTAL_GLACIS_CALLDATA=0x... FRAXTAL_BASE_DESTINATION=0x... \
///             FRAXTAL_BRIDGE_AMOUNT=... FRAXTAL_NATIVE_FEE=... forge test --match-test Fraxtal
contract CrossChainBridgingForkTest is Test {
    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");

    // Deterministic deploy for the Base 0x lane: the swapper address must be known off-chain to fetch
    // 0x AllowanceHolder calldata (the quote's `taker` is the WETH recipient). Fixed args + CREATE2 via
    // the canonical factory (`CREATE2_FACTORY` is inherited from forge-std `Base`).
    bytes32 internal constant BASE_SWAP_SALT = bytes32(uint256(0xB0A2D));
    address internal constant BASE_SWAP_OWNER = address(0xA11CE);
    address internal constant BASE_SWAP_KEEPER = address(0xB0B);
    address internal constant BASE_SWAP_FEE_COLLECTOR = address(0xFEE);

    /* -------------------------------- ETH / Ink Across V4 ------------------------------ */

    function testFork_Ethereum_AcrossV4Deposits() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        _runAcrossLane(CrossChainConfig.lifiDiamond(CrossChainConfig.CHAIN_ETHEREUM), CrossChainConfig.ETHEREUM_WETH);
    }

    function testFork_Ink_AcrossV4Deposits() public {
        string memory rpc = vm.envOr("INK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        _runAcrossLane(CrossChainConfig.lifiDiamond(CrossChainConfig.CHAIN_INK), CrossChainConfig.INK_WETH);
    }

    function testFork_Arbitrum_AcrossV4Deposits() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        _runAcrossLane(CrossChainConfig.lifiDiamond(CrossChainConfig.CHAIN_ARBITRUM), CrossChainConfig.ARBITRUM_WETH);
    }

    /// @dev Builds a fully-pinned pure Across V4 deposit and asserts the real facet + SpokePool
    ///      accept it, pulling exactly `amount` of WETH and leaving the approval reset.
    function _runAcrossLane(
        address diamond,
        address weth
    ) internal {
        assertGt(diamond.code.length, 0, "diamond has no code");
        assertGt(weth.code.length, 0, "weth has no code");

        address dest = makeAddr("baseSwapper");
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = CrossChainConfig.ACROSS_V4_SELECTOR;
        RevenueBridger bridger = new RevenueBridger(
            owner,
            diamond,
            weth,
            dest,
            CrossChainConfig.BASE_WETH,
            keeper,
            false,
            CrossChainConfig.DEFAULT_MAX_FEE_BPS,
            sels
        );

        uint256 amount = 1e17;
        deal(weth, address(bridger), amount);

        bytes memory cd = _buildAcrossCalldata(address(bridger), dest, weth, amount);
        uint256 balBefore = IERC20(weth).balanceOf(address(bridger));

        vm.prank(keeper);
        bridger.bridgeToBase(amount, cd);

        assertEq(balBefore - IERC20(weth).balanceOf(address(bridger)), amount, "exactly amount deposited");
        assertEq(IERC20(weth).allowance(address(bridger), diamond), 0, "approval reset");
    }

    function _buildAcrossCalldata(
        address bridger,
        address dest,
        address weth,
        uint256 amount
    ) internal view returns (bytes memory) {
        ILiFi.BridgeData memory bd = ILiFi.BridgeData({
            transactionId: bytes32(uint256(1)),
            bridge: "across",
            integrator: "boardwalk",
            referrer: address(0),
            sendingAssetId: weth,
            receiver: dest,
            minAmount: amount,
            destinationChainId: CrossChainConfig.BASE_CHAIN_ID,
            hasSourceSwaps: false,
            hasDestinationCall: false
        });
        ILiFi.AcrossV4Data memory ad = ILiFi.AcrossV4Data({
            receiverAddress: bytes32(uint256(uint160(dest))),
            refundAddress: bytes32(uint256(uint160(bridger))),
            sendingAssetId: bytes32(uint256(uint160(weth))),
            receivingAssetId: bytes32(uint256(uint160(CrossChainConfig.BASE_WETH))),
            outputAmount: amount * (10_000 - CrossChainConfig.DEFAULT_MAX_FEE_BPS) / 10_000,
            outputAmountMultiplier: 0,
            exclusiveRelayer: bytes32(0),
            quoteTimestamp: uint32(block.timestamp - 60),
            fillDeadline: uint32(block.timestamp + 1 hours),
            exclusivityParameter: 0,
            message: ""
        });
        return abi.encodeWithSelector(CrossChainConfig.ACROSS_V4_SELECTOR, bd, ad);
    }

    /* --------------------------------- Katana Symbiosis -------------------------------- */

    function testFork_Katana_SymbiosisBridges() public {
        string memory rpc = vm.envOr("KATANA_RPC_URL", string(""));
        bytes memory cd = vm.envOr("KATANA_SYMBIOSIS_CALLDATA", bytes(""));
        if (bytes(rpc).length == 0 || cd.length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        address diamond = CrossChainConfig.lifiDiamond(CrossChainConfig.CHAIN_KATANA);
        address kat = vm.envAddress("KATANA_RAISE_TOKEN");
        address dest = vm.envAddress("KATANA_BASE_DESTINATION");
        uint256 amount = vm.envUint("KATANA_BRIDGE_AMOUNT");
        uint256 nativeFee = vm.envOr("KATANA_NATIVE_FEE", uint256(0));
        assertGt(diamond.code.length, 0, "diamond has no code");

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = CrossChainConfig.SYMBIOSIS_SELECTOR;
        RevenueBridger bridger = new RevenueBridger(
            owner,
            diamond,
            kat,
            dest,
            CrossChainConfig.BASE_WETH,
            keeper,
            true,
            CrossChainConfig.DEFAULT_MAX_FEE_BPS,
            sels
        );

        deal(kat, address(bridger), amount);
        vm.deal(keeper, nativeFee * 2 + 1 ether);
        uint256 balBefore = IERC20(kat).balanceOf(address(bridger));

        vm.prank(keeper);
        bridger.bridgeToBase{value: nativeFee}(amount, cd);

        uint256 spent = balBefore - IERC20(kat).balanceOf(address(bridger));
        assertGt(spent, 0, "KAT bridged");
        assertLe(spent, amount, "delta <= amount");
        assertEq(IERC20(kat).allowance(address(bridger), diamond), 0, "approval reset");
    }

    /* ---------------------------------- Fraxtal Glacis --------------------------------- */

    function testFork_Fraxtal_GlacisBridges() public {
        string memory rpc = vm.envOr("FRAXTAL_RPC_URL", string(""));
        bytes memory cd = vm.envOr("FRAXTAL_GLACIS_CALLDATA", bytes(""));
        if (bytes(rpc).length == 0 || cd.length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        address diamond = CrossChainConfig.lifiDiamond(CrossChainConfig.CHAIN_FRAXTAL);
        address frxusd = vm.envOr("FRAXTAL_RAISE_TOKEN", CrossChainConfig.FRAXTAL_FRXUSD);
        address dest = vm.envAddress("FRAXTAL_BASE_DESTINATION");
        uint256 amount = vm.envUint("FRAXTAL_BRIDGE_AMOUNT");
        uint256 nativeFee = vm.envOr("FRAXTAL_NATIVE_FEE", uint256(0));
        assertGt(diamond.code.length, 0, "diamond has no code");

        bytes4[] memory sels = new bytes4[](1);
        sels[0] = CrossChainConfig.GLACIS_SELECTOR;
        RevenueBridger bridger = new RevenueBridger(
            owner,
            diamond,
            frxusd,
            dest,
            CrossChainConfig.BASE_WETH,
            keeper,
            true,
            CrossChainConfig.DEFAULT_MAX_FEE_BPS,
            sels
        );

        deal(frxusd, address(bridger), amount);
        vm.deal(keeper, nativeFee * 2 + 1 ether);
        uint256 balBefore = IERC20(frxusd).balanceOf(address(bridger));

        vm.prank(keeper);
        bridger.bridgeToBase{value: nativeFee}(amount, cd);

        uint256 spent = balBefore - IERC20(frxusd).balanceOf(address(bridger));
        assertGt(spent, 0, "frxUSD bridged");
        assertLe(spent, amount, "delta <= amount");
        assertEq(IERC20(frxusd).allowance(address(bridger), diamond), 0, "approval reset");
    }

    /* ------------------------------------- Base --------------------------------------- */

    function testFork_Base_SwapAndForward() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        bytes memory cd = vm.envOr("BASE_0X_CALLDATA", bytes(""));
        if (bytes(rpc).length == 0 || cd.length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        address ah = CrossChainConfig.ZEROX_ALLOWANCE_HOLDER;
        assertGt(ah.code.length, 0, "AllowanceHolder has no code");
        address weth = CrossChainConfig.BASE_WETH;
        address frxusd = vm.envOr("BASE_FRXUSD", CrossChainConfig.BASE_FRXUSD);
        uint256 amount = vm.envUint("BASE_SWAP_AMOUNT");
        uint256 minOut = vm.envOr("BASE_SWAP_MINOUT", uint256(0));

        // Deploy at a deterministic CREATE2 address (fixed args + salt) so the 0x quote's `taker`
        // — the WETH recipient baked into the calldata — can be computed off-chain beforehand.
        BaseRevenueSwapper swapper = _deployDeterministicSwapper(ah, weth);

        deal(frxusd, address(swapper), amount);

        vm.prank(BASE_SWAP_KEEPER);
        swapper.swapAndForward(frxusd, cd, minOut);

        assertGt(IERC20(weth).balanceOf(BASE_SWAP_FEE_COLLECTOR), 0, "WETH forwarded to FeeCollector");
        assertEq(IERC20(weth).balanceOf(address(swapper)), 0, "swapper drained of WETH");
        assertEq(IERC20(frxusd).allowance(address(swapper), ah), 0, "approval reset");
    }

    /// @dev Deploys the swapper via the canonical CREATE2 factory with fixed constructor args, so the
    ///      address is reproducible off-chain (needed to pin the 0x quote's `taker` = WETH recipient).
    function _deployDeterministicSwapper(
        address ah,
        address weth
    ) internal returns (BaseRevenueSwapper) {
        assertGt(CREATE2_FACTORY.code.length, 0, "CREATE2 factory not on this chain");
        bytes memory initCode = abi.encodePacked(
            type(BaseRevenueSwapper).creationCode,
            abi.encode(BASE_SWAP_OWNER, ah, weth, BASE_SWAP_FEE_COLLECTOR, BASE_SWAP_KEEPER)
        );
        (bool ok, bytes memory ret) = CREATE2_FACTORY.call(abi.encodePacked(BASE_SWAP_SALT, initCode));
        require(ok && ret.length == 20, "create2 deploy failed");
        return BaseRevenueSwapper(address(uint160(bytes20(ret))));
    }

    function testFork_Base_ForwardWethToFeeCollector() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        address weth = CrossChainConfig.BASE_WETH;
        address feeCollector = makeAddr("feeCollector");
        BaseRevenueSwapper swapper =
            new BaseRevenueSwapper(owner, CrossChainConfig.ZEROX_ALLOWANCE_HOLDER, weth, feeCollector, keeper);

        uint256 amount = 1e18;
        deal(weth, address(swapper), amount); // bridged-in WETH from ETH/Ink lanes
        swapper.forwardWeth();

        assertEq(IERC20(weth).balanceOf(feeCollector), amount, "bridged WETH forwarded");
    }
}

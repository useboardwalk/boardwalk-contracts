// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RevenueBridger} from "src/crosschain/RevenueBridger.sol";
import {EthereumRevenueSwapper} from "src/crosschain/EthereumRevenueSwapper.sol";
import {ILiFi} from "src/interfaces/ILiFi.sol";
import {CrossChainConfig} from "script/CrossChainConfig.sol";

/// @title CrossChainBridgingForkTest
/// @notice Per-lane mainnet fork tests against the real LiFi Diamonds, Across SpokePools, and the
///         0x AllowanceHolder. One generic `RevenueBridger` serves every non-Ethereum lane
///         (Base, Arbitrum, Robinhood — all pure Across V4 WETH lanes to Ethereum).
/// @dev    Each test is env-gated and self-skips unless its `<CHAIN>_RPC_URL` is set. The Across
///         lanes construct pinned calldata in-test (so `refundAddress == bridger`, which a
///         pre-captured fixture cannot know). The Ethereum 0x swap leg needs aggregator calldata
///         that cannot be built on-chain, so it consumes env fixtures and skips when absent.
///
///         Examples:
///           BASE_RPC_URL=https://mainnet.base.org forge test --match-contract CrossChainBridgingFork -vvv
///           ETH_RPC_URL=... ETH_0X_CALLDATA=0x... ETH_SWAP_TOKENIN=0x... ETH_SWAP_AMOUNT=... \
///             forge test --match-test SwapAndForward
contract CrossChainBridgingForkTest is Test {
    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");

    // Deterministic deploy for the Ethereum 0x lane: the swapper address must be known off-chain to
    // fetch 0x AllowanceHolder calldata (the quote's `taker` is the WETH recipient). Fixed args +
    // CREATE2 via the canonical factory (`CREATE2_FACTORY` is inherited from forge-std `Base`).
    bytes32 internal constant ETH_SWAP_SALT = bytes32(uint256(0xB0A2D));
    address internal constant ETH_SWAP_OWNER = address(0xA11CE);
    address internal constant ETH_SWAP_KEEPER = address(0xB0B);
    address internal constant ETH_SWAP_FEE_COLLECTOR = address(0xFEE);

    /* -------------------------- Base / Arbitrum / Robinhood Across V4 ------------------------ */

    function testFork_Base_AcrossV4Deposits() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        _runAcrossLane(CrossChainConfig.lifiDiamond(CrossChainConfig.CHAIN_BASE), CrossChainConfig.BASE_WETH);
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

    function testFork_Robinhood_AcrossV4Deposits() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        _runAcrossLane(CrossChainConfig.lifiDiamond(CrossChainConfig.CHAIN_ROBINHOOD), CrossChainConfig.ROBINHOOD_WETH);
    }

    /// @dev Builds a fully-pinned pure Across V4 deposit and asserts the real facet + SpokePool
    ///      accept it, pulling exactly `amount` of WETH and leaving the approval reset.
    function _runAcrossLane(
        address diamond,
        address weth
    ) internal {
        assertGt(diamond.code.length, 0, "diamond has no code");
        assertGt(weth.code.length, 0, "weth has no code");

        address dest = makeAddr("ethereumSwapper");
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = CrossChainConfig.ACROSS_V4_SELECTOR;
        RevenueBridger bridger = new RevenueBridger(
            owner,
            diamond,
            weth,
            dest,
            CrossChainConfig.ETHEREUM_WETH,
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
        bridger.bridgeToEthereum(amount, cd);

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
            destinationChainId: CrossChainConfig.ETHEREUM_CHAIN_ID,
            hasSourceSwaps: false,
            hasDestinationCall: false
        });
        ILiFi.AcrossV4Data memory ad = ILiFi.AcrossV4Data({
            receiverAddress: bytes32(uint256(uint160(dest))),
            refundAddress: bytes32(uint256(uint160(bridger))),
            sendingAssetId: bytes32(uint256(uint160(weth))),
            receivingAssetId: bytes32(uint256(uint160(CrossChainConfig.ETHEREUM_WETH))),
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

    /* ------------------------------------ Ethereum ------------------------------------ */

    function testFork_Ethereum_SwapAndForward() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        bytes memory cd = vm.envOr("ETH_0X_CALLDATA", bytes(""));
        address tokenIn = vm.envOr("ETH_SWAP_TOKENIN", address(0));
        uint256 amount = vm.envOr("ETH_SWAP_AMOUNT", uint256(0));
        if (bytes(rpc).length == 0 || cd.length == 0 || tokenIn == address(0) || amount == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        address ah = CrossChainConfig.ZEROX_ALLOWANCE_HOLDER;
        assertGt(ah.code.length, 0, "AllowanceHolder has no code");
        address weth = CrossChainConfig.ETHEREUM_WETH;
        uint256 minOut = vm.envOr("ETH_SWAP_MINOUT", uint256(0));

        // Deploy at a deterministic CREATE2 address (fixed args + salt) so the 0x quote's `taker`
        // — the WETH recipient baked into the calldata — can be computed off-chain beforehand.
        EthereumRevenueSwapper swapper = _deployDeterministicSwapper(ah, weth);

        deal(tokenIn, address(swapper), amount);

        vm.prank(ETH_SWAP_KEEPER);
        swapper.swapAndForward(tokenIn, cd, minOut);

        assertGt(IERC20(weth).balanceOf(ETH_SWAP_FEE_COLLECTOR), 0, "WETH forwarded to FeeCollector");
        assertEq(IERC20(weth).balanceOf(address(swapper)), 0, "swapper drained of WETH");
        assertEq(IERC20(tokenIn).allowance(address(swapper), ah), 0, "approval reset");
    }

    /// @dev Deploys the swapper via the canonical CREATE2 factory with fixed constructor args, so the
    ///      address is reproducible off-chain (needed to pin the 0x quote's `taker` = WETH recipient).
    function _deployDeterministicSwapper(
        address ah,
        address weth
    ) internal returns (EthereumRevenueSwapper) {
        assertGt(CREATE2_FACTORY.code.length, 0, "CREATE2 factory not on this chain");
        bytes memory initCode = abi.encodePacked(
            type(EthereumRevenueSwapper).creationCode,
            abi.encode(ETH_SWAP_OWNER, ah, weth, ETH_SWAP_FEE_COLLECTOR, ETH_SWAP_KEEPER)
        );
        (bool ok, bytes memory ret) = CREATE2_FACTORY.call(abi.encodePacked(ETH_SWAP_SALT, initCode));
        require(ok && ret.length == 20, "create2 deploy failed");
        return EthereumRevenueSwapper(address(uint160(bytes20(ret))));
    }

    function testFork_Ethereum_ForwardWethToFeeCollector() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        address weth = CrossChainConfig.ETHEREUM_WETH;
        address feeCollector = makeAddr("feeCollector");
        EthereumRevenueSwapper swapper =
            new EthereumRevenueSwapper(owner, CrossChainConfig.ZEROX_ALLOWANCE_HOLDER, weth, feeCollector, keeper);

        uint256 amount = 1e18;
        deal(weth, address(swapper), amount); // bridged-in WETH from the source lanes
        swapper.forwardWeth();

        assertEq(IERC20(weth).balanceOf(feeCollector), amount, "bridged WETH forwarded");
    }
}

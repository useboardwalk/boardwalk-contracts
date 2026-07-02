// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {UnsoldBurner} from "src/token/UnsoldBurner.sol";
import {MockERC20} from "test/bws/UnsoldBurnerMocks.sol";

/// @dev Byte-identical layout to Uniswap's `AuctionParameters`
///      (continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol:16-28).
struct AuctionParameters {
    address currency;
    address tokensRecipient;
    address fundsRecipient;
    uint64 startBlock;
    uint64 endBlock;
    uint64 claimBlock;
    uint256 tickSpacing;
    address validationHook;
    uint256 floorPrice;
    uint128 requiredCurrencyRaised;
    bytes auctionStepsData;
}

/// @dev The real CCA factory's `IDistributorFactory.create`.
interface ICcaFactory {
    function create(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt
    ) external returns (address distributor);
}

/// @dev The subset of the real `ContinuousClearingAuction` surface this fork test drives/reads.
interface ICcaAuctionFull {
    function tokensRecipient() external view returns (address);
    function token() external view returns (address);
    function totalSupply() external view returns (uint128);
    function onTokensReceived() external;
    function sweepUnsoldTokensBlock() external view returns (uint256);
    function isGraduated() external view returns (bool);
}

/// @notice Arbitrum-fork test for `UnsoldBurner` against the deployed Uniswap CCA. Creates a real auction
///         through the on-chain factory with `tokensRecipient = UnsoldBurner`, drives it to a
///         non-graduation sweep, and checks the unsold BWS lands at DEAD via `UnsoldBurner.sweep`.
/// @dev On Arbitrum the auction reads its block number from the ArbSys precompile (0x64, `arbBlockNumber()`),
///      not the EVM `NUMBER` opcode, so `vm.roll` has no effect and we `vm.mockCall` ArbSys to advance its
///      clock. That is the only stub; the factory and auction are real deployed bytecode.
///      Run: forge test --match-contract UnsoldBurnerForkTest --fork-url https://arb1.arbitrum.io/rpc
contract UnsoldBurnerForkTest is Test {
    // Deployed Arbitrum One CCA addresses.
    address internal constant CCA_FACTORY = 0x00cCa200BF124dBfA848937c553864f4B4CE0632;
    address internal constant LIQUIDITY_LAUNCHER = 0x00004c4ccc709Ef590F7C81102C0689F0263D4e9;
    address internal constant LBP_STRATEGY = 0x18608AD558dcD233F7854242bbAef73988Bee000;
    address internal constant CCA_LENS = 0xc3C65F5453A3674aDb693cbdA3C842545cD30f53;

    address internal constant ARB_SYS = 0x0000000000000000000000000000000000000064;
    bytes4 internal constant ARB_BLOCK_NUMBER_SELECTOR = 0xa3b1b31d;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant RESOLUTION = 96;

    UnsoldBurner internal burner;
    MockERC20 internal bws;
    address internal fundsRecipient = makeAddr("fundsRecipient");

    function setUp() public {
        require(CCA_FACTORY.code.length > 0, "not an Arbitrum fork");
        require(LIQUIDITY_LAUNCHER.code.length > 0, "launcher missing");
        require(LBP_STRATEGY.code.length > 0, "strategy missing");
        require(CCA_LENS.code.length > 0, "lens missing");

        bws = new MockERC20("Boardwalk", "BWS");
        burner = new UnsoldBurner(address(bws));
    }

    /// @dev Point the auction's ArbSys-backed L2 clock at `b`.
    function _setArbBlock(
        uint256 b
    ) internal {
        vm.mockCall(ARB_SYS, abi.encodeWithSelector(ARB_BLOCK_NUMBER_SELECTOR), abi.encode(b));
    }

    /// @dev Create a real auction through the deployed factory with `UnsoldBurner` as the tokens recipient.
    ///      Uses proven-valid floor/tick/step params; `requiredCurrencyRaised` is set unreachable so the
    ///      no-bid auction never graduates (sweep then returns the full offered supply).
    function _createRealAuction(
        uint128 offered,
        uint256 baseBlock
    ) internal returns (ICcaAuctionFull auction) {
        _setArbBlock(baseBlock);
        // Two 1%-MPS steps of 50 blocks each: abi.encodePacked(uint24 mps, uint40 blockDelta) per step.
        bytes memory steps = abi.encodePacked(uint24(100_000), uint40(50), uint24(100_000), uint40(50));
        AuctionParameters memory p = AuctionParameters({
            currency: address(0), // native ETH raise
            tokensRecipient: address(burner),
            fundsRecipient: fundsRecipient,
            startBlock: uint64(baseBlock),
            endBlock: uint64(baseBlock + 100),
            claimBlock: uint64(baseBlock + 110),
            tickSpacing: 100 << RESOLUTION,
            validationHook: address(0),
            floorPrice: 1000 << RESOLUTION,
            requiredCurrencyRaised: uint128(1000e18), // unreachable with no bids -> never graduates
            auctionStepsData: steps
        });
        address a = ICcaFactory(CCA_FACTORY).create(address(bws), offered, abi.encode(p), bytes32(0));
        auction = ICcaAuctionFull(a);
    }

    /// @dev The deployed factory accepts the burner (a contract) as `tokensRecipient` and stores it — the
    ///      wiring the launch runbook relies on.
    function testFork_RealFactory_StoresBurnerAsTokensRecipient() public {
        uint128 offered = 219_466e18;
        ICcaAuctionFull auction = _createRealAuction(offered, 1_000_000);

        assertEq(auction.tokensRecipient(), address(burner), "burner is tokensRecipient");
        assertEq(auction.token(), address(bws), "auction token is BWS");
        assertEq(auction.totalSupply(), offered, "offered supply stored");
    }

    /// @dev End-to-end: a non-graduated auction's full offered supply is swept to the burner and burned.
    function testFork_RealAuction_Sweep_BurnsFullUnsoldSupplyToDead() public {
        uint128 offered = 219_466e18;
        uint256 baseBlock = 1_000_000;
        ICcaAuctionFull auction = _createRealAuction(offered, baseBlock);

        // Fund the auction with the offered supply and notify it (mirrors the launcher/LBP deposit).
        bws.mint(address(auction), offered);
        auction.onTokensReceived();

        // Advance the auction's ArbSys clock past the end block so it is over + can be end-checkpointed.
        _setArbBlock(baseBlock + 200);
        assertFalse(auction.isGraduated(), "auction did not graduate (no bids)");

        // Anyone can trigger the sweep+burn; the real auction pushes the full offered supply to the burner.
        burner.sweep(address(auction));

        assertEq(bws.balanceOf(DEAD), offered, "full offered supply burned to DEAD");
        assertEq(bws.balanceOf(address(auction)), 0, "auction emptied");
        assertEq(bws.balanceOf(address(burner)), 0, "burner emptied");
        assertTrue(auction.sweepUnsoldTokensBlock() != 0, "real auction marked swept");
    }
}

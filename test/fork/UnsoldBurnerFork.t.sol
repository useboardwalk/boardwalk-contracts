// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {UnsoldBurner} from "src/token/UnsoldBurner.sol";
import {MockERC20} from "test/bwlk/UnsoldBurnerMocks.sol";

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

/// @notice Ethereum-mainnet-fork test for `UnsoldBurner` against the deployed Uniswap CCA. Creates a
///         real auction through the on-chain factory with `tokensRecipient = UnsoldBurner`, drives it
///         to a non-graduation sweep, and checks the unsold BWLK lands at DEAD via `UnsoldBurner.sweep`.
/// @dev On mainnet the auction's clock is plain block.number, so `vm.roll` drives it - no stubs;
///      the factory and auction are real deployed bytecode.
///      Run: forge test --match-contract UnsoldBurnerForkTest --fork-url https://ethereum-rpc.publicnode.com
contract UnsoldBurnerForkTest is Test {
    // Deployed Ethereum mainnet CCA addresses (the factory is the v3.1.0 strategy's own initializerFactory).
    address internal constant CCA_FACTORY = 0x000000001F26a0044BaA66024e7b6599c61963F8;
    address internal constant LIQUIDITY_LAUNCHER = 0x00004c4ccc709Ef590F7C81102C0689F0263D4e9;
    address internal constant LBP_STRATEGY = 0x49380c4EfaB1b491006aF7FabAB8B3459F0E6000;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant RESOLUTION = 96;

    UnsoldBurner internal burner;
    MockERC20 internal bwlk;
    address internal fundsRecipient = makeAddr("fundsRecipient");

    bool internal forked;

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function setUp() public {
        // Run with --fork-url, or self-fork from ETHEREUM_RPC_URL; without either the suite skips
        // (CI runs with no RPC configured).
        if (CCA_FACTORY.code.length == 0) {
            string memory rpcUrl = vm.envOr("ETHEREUM_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) return;
            vm.createSelectFork(rpcUrl);
        }
        forked = true;
        require(LIQUIDITY_LAUNCHER.code.length > 0, "launcher missing");
        require(LBP_STRATEGY.code.length > 0, "strategy missing");

        bwlk = new MockERC20("Boardwalk", "BWLK");
        burner = new UnsoldBurner(address(bwlk));
    }

    /// @dev Create a real auction through the deployed factory with `UnsoldBurner` as the tokens recipient.
    ///      Uses proven-valid floor/tick/step params; `requiredCurrencyRaised` is set unreachable so the
    ///      no-bid auction never graduates (sweep then returns the full offered supply).
    function _createRealAuction(
        uint128 offered,
        uint256 baseBlock
    ) internal returns (ICcaAuctionFull auction) {
        vm.roll(baseBlock);
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
        address a = ICcaFactory(CCA_FACTORY).create(address(bwlk), offered, abi.encode(p), bytes32(0));
        auction = ICcaAuctionFull(a);
    }

    /// @dev The deployed factory accepts the burner (a contract) as `tokensRecipient` and stores it — the
    ///      wiring the launch script relies on.
    function testFork_RealFactory_StoresBurnerAsTokensRecipient() public onlyFork {
        uint128 offered = 219_466e18;
        ICcaAuctionFull auction = _createRealAuction(offered, block.number + 10);

        assertEq(auction.tokensRecipient(), address(burner), "burner is tokensRecipient");
        assertEq(auction.token(), address(bwlk), "auction token is BWLK");
        assertEq(auction.totalSupply(), offered, "offered supply stored");
    }

    /// @dev End-to-end: a non-graduated auction's full offered supply is swept to the burner and burned.
    function testFork_RealAuction_Sweep_BurnsFullUnsoldSupplyToDead() public onlyFork {
        uint128 offered = 219_466e18;
        uint256 baseBlock = block.number + 10;
        ICcaAuctionFull auction = _createRealAuction(offered, baseBlock);

        // Fund the auction with the offered supply and notify it (mirrors the launcher/LBP deposit).
        bwlk.mint(address(auction), offered);
        auction.onTokensReceived();

        // Advance past the end block so the auction is over + can be end-checkpointed.
        vm.roll(baseBlock + 200);
        assertFalse(auction.isGraduated(), "auction did not graduate (no bids)");

        // Anyone can trigger the sweep+burn; the real auction pushes the full offered supply to the burner.
        burner.sweep(address(auction));

        assertEq(bwlk.balanceOf(DEAD), offered, "full offered supply burned to DEAD");
        assertEq(bwlk.balanceOf(address(auction)), 0, "auction emptied");
        assertEq(bwlk.balanceOf(address(burner)), 0, "burner emptied");
        assertTrue(auction.sweepUnsoldTokensBlock() != 0, "real auction marked swept");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title ICcaAuctionFactory
/// @notice The Uniswap ContinuousClearingAuctionFactory call the BWS CCA launch script makes: the
///         CREATE2 address prediction used to print (and post-verify) the auction address the
///         LBPStrategy will deploy. The launch itself never calls the factory directly.
/// @dev    `AuctionParameters` MUST stay byte-identical to Uniswap/continuous-clearing-auction
///         `src/interfaces/IContinuousClearingAuction.sol` — it is abi-encoded into the initializer
///         config bytes and into the CREATE2 init-code hash.
interface ICcaAuctionFactory {
    /// @notice Constructor parameters for an auction (token + supply are separate factory args).
    /// @dev On Arbitrum the block fields are ArbSys L2 block numbers (precompile 0x64,
    ///      `arbBlockNumber()`), NOT the EVM `NUMBER` opcode. `tickSpacing`/`floorPrice` are Q96
    ///      currency-per-token prices. `auctionStepsData` packs one step per 8 bytes:
    ///      `abi.encodePacked(uint24 mps, uint40 blockDelta)`.
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

    /// @notice Predicts the auction address `create` would deploy for these parameters.
    /// @param sender The address that would call `create` (the LBPStrategy for a launcher flow).
    function getAddress(
        address token,
        uint256 amount,
        bytes calldata configData,
        bytes32 salt,
        address sender
    ) external view returns (address distributor);
}

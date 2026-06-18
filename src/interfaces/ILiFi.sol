// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title ILiFi
/// @notice Minimal consumer-side decode types for the LiFi Diamond. `RevenueBridger` calls the
///         Diamond low-level (allowlisted `bytes4` + `abi.decode` pinning), so this declares only
///         the structs needed to decode and pin keeper-supplied route calldata.
/// @dev    Layouts MUST stay byte-identical to LiFi's canonical definitions or `abi.decode` reads
///         garbage. Mirrored from lifinance/contracts:
///         - `BridgeData`     == `src/Interfaces/ILiFi.sol` (v1.0.1)
///         - `SwapData`       == `src/Libraries/LibSwap.sol` (v1.1.0)
///         - `AcrossV4Data`   == `src/Facets/AcrossFacetV4.sol` (v1.0.0)
interface ILiFi {
    /// @notice First parameter of every standard (non-Packed) LiFi facet call.
    struct BridgeData {
        bytes32 transactionId;
        string bridge;
        string integrator;
        address referrer;
        address sendingAssetId;
        address receiver;
        uint256 minAmount;
        uint256 destinationChainId;
        bool hasSourceSwaps;
        bool hasDestinationCall;
    }

    /// @notice Per-leg swap data carried by composed (`swapAndStartBridgeTokensVia*`) routes.
    struct SwapData {
        address callTo;
        address approveTo;
        address sendingAssetId;
        address receivingAssetId;
        uint256 fromAmount;
        bytes callData;
        bool requiresDeposit;
    }

    /// @notice Facet-specific second parameter of `startBridgeTokensViaAcrossV4`. All addresses are
    ///         `bytes32` in V4 (non-EVM support). `refundAddress` is the Across depositor and the
    ///         origin-chain recipient of an unfilled-deposit refund; `sendingAssetId` is the
    ///         SpokePool `inputToken` (the facet uses this, not `BridgeData.sendingAssetId`).
    struct AcrossV4Data {
        bytes32 receiverAddress;
        bytes32 refundAddress;
        bytes32 sendingAssetId;
        bytes32 receivingAssetId;
        uint256 outputAmount;
        uint128 outputAmountMultiplier;
        bytes32 exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityParameter;
        bytes message;
    }
}

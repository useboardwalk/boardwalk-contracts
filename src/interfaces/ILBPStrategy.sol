// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title ILBPStrategy
/// @notice The Uniswap LBPStrategy surface the BWS CCA launch touches. The strategy is the ONLY
///         address allowed to sweep a graduated auction's raise, and it can only sweep auctions it
///         registered itself in `initializeDistribution` — which is why the launch must go through
///         the LiquidityLauncher and never the raw CCA factory.
/// @dev    Struct layouts MUST stay byte-identical to Uniswap/liquidity-launcher
///         (`src/libraries/MigratorParams.sol` + `src/types/PositionPlannerTypes.sol`): they are
///         abi-encoded into `Distribution.configData` and hashed into the initializer's CREATE2 salt.
interface ILBPStrategy {
    /// @notice Migration parameters for an initializer (== upstream `MigratorParameters`).
    /// @dev `positionDefinitions` is an abi-encoded `PositionDefinition[]`; `lpAllocationSchedule`
    ///      an abi-encoded `LiquidityAllocationBracket[]`.
    struct MigratorParameters {
        address token;
        address currency;
        uint64 migrationBlock;
        uint128 reservedTokenAmountForLP;
        address recipient;
        address positionRecipient;
        PoolParameters poolParameters;
        bytes positionDefinitions;
        bytes lpAllocationSchedule;
    }

    /// @notice Parameters for the v4 pool the strategy initializes at migration.
    struct PoolParameters {
        uint24 fee;
        int24 tickSpacing;
        address hook;
    }

    /// @notice A weighted LP position as tick offsets from the pool's initial tick. The sentinel
    ///         pair (offsetLower = MIN_TICK, offsetUpper = MAX_TICK) resolves to full range.
    struct PositionDefinition {
        int24 offsetLower;
        int24 offsetUpper;
        uint24 weight; // mps, 1e7 = 100%
        address overridePositionRecipient; // address(0) = MigratorParameters.positionRecipient
    }

    /// @notice One bracket of the raised-currency-to-LP schedule. Brackets must be strictly
    ///         ascending by `lowerThreshold` and the first `lowerThreshold` must be 0.
    struct LiquidityAllocationBracket {
        uint128 lowerThreshold;
        uint24 rate; // mps, 1e7 = 100%
    }

    /// @notice Permissionless post-auction step: sweeps the raise, initializes the v4 pool, mints
    ///         the LP to `positionRecipient`. Only callable after `migrationBlock` (ArbSys clock).
    function migrate(
        address initializer
    ) external;

    /// @notice Stored migration parameters; `migrationBlock == 0` means never registered (a
    ///         `migrate` on such an initializer reverts `InitializerNotRegistered`).
    function initializers(
        address initializer
    ) external view returns (MigratorParameters memory);

    /// @notice The initializer (CCA) factory the strategy creates auctions through.
    function initializerFactory() external view returns (address);

    /// @notice The v4 position manager the strategy mints LP positions through.
    function positionManager() external view returns (address);
}

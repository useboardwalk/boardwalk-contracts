// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title ILiquidityLauncher
/// @notice The Uniswap LiquidityLauncher calls the BWS CCA launch script makes. `depositToken` pulls
///         from the caller via Permit2 (NOT a plain ERC20 allowance), and the launcher keeps no
///         per-depositor accounting, so deposit + distribute MUST be batched in one `multicall` —
///         tokens parked between separate txs are distributable by anyone.
/// @dev    Mirrors Uniswap/liquidity-launcher `src/LiquidityLauncher.sol` + `src/types/Distribution.sol`.
///         `Distribution` MUST stay byte-identical to upstream (it is abi-encoded into calldata).
interface ILiquidityLauncher {
    /// @notice One distribution instruction: which strategy, how many tokens, strategy-specific data.
    struct Distribution {
        address strategy;
        uint128 amount;
        bytes configData;
    }

    /// @notice Pulls `amount` of `token` from msg.sender into the launcher via Permit2.
    function depositToken(
        address token,
        uint160 amount
    ) external;

    /// @notice Approves `distribution.strategy` for `distribution.amount` and calls its
    ///         `initializeDistribution(token, amount, configData, keccak256(abi.encode(msg.sender, salt)))`.
    function distributeToken(
        address token,
        Distribution calldata distribution,
        bytes32 salt
    ) external;

    /// @notice Self-delegatecall batcher; reverts bubble up.
    function multicall(
        bytes[] calldata data
    ) external returns (bytes[] memory results);

    /// @notice The Permit2 deployment `depositToken` pulls through.
    function permit2() external view returns (address);
}

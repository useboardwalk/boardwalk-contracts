// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @title IPermit2
/// @notice The one Permit2 (AllowanceTransfer) call the BWLK CCA launch script makes: granting the
///         LiquidityLauncher a Permit2 allowance so its `depositToken` can pull the launch bucket.
///         The owner must also hold a plain ERC20 approval to Permit2 itself.
interface IPermit2 {
    /// @notice Sets `spender`'s allowance over the caller's `token`, valid until `expiration`.
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
}

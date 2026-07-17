// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

/// @notice Minimal consumer-side interface for a Morphex MintableBaseToken (e.g. bnBWLK multiplier
///         points). Declares only the calls the migration contract makes.
/// @dev The token additionally exposes the standard ERC20 surface; cast to IERC20 for approvals.
interface IMintable {
    function mint(
        address account,
        uint256 amount
    ) external;
}

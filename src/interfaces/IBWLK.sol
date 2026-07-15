// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice BWLK-specific additions on top of the standard ERC20 surface (inherited from IERC20 per
///         the standard-extension carve-out).
interface IBWLK is IERC20 {
    error ZeroAddress();

    function MAX_SUPPLY() external view returns (uint256);

    function getCCIPAdmin() external view returns (address);
}

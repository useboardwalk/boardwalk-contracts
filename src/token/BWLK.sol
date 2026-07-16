// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title BWLK
/// @notice Boardwalk's fixed-supply protocol token on Ethereum. The entire supply is minted once at
///         deployment; there is no minter, owner, pause, or transfer-gating.
contract BWLK is ERC20 {
    /// @notice Fixed maximum supply, minted in full at construction.
    uint256 public constant MAX_SUPPLY = 3_150_000e18;

    /// @dev The address registered as the token's CCIP admin.
    address private immutable _CCIP_ADMIN;

    error ZeroAddress();

    /// @param recipient Receives the entire `MAX_SUPPLY` at deployment.
    /// @param ccipAdmin The address registered as the token's CCIP admin.
    constructor(
        address recipient,
        address ccipAdmin
    ) ERC20("Boardwalk", "BWLK") {
        if (recipient == address(0) || ccipAdmin == address(0)) revert ZeroAddress();
        _CCIP_ADMIN = ccipAdmin;
        _mint(recipient, MAX_SUPPLY);
    }

    function getCCIPAdmin() external view returns (address) {
        return _CCIP_ADMIN;
    }
}

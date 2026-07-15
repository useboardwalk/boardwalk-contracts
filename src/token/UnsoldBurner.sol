// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICcaAuction} from "../interfaces/ICcaAuction.sol";

/// @title UnsoldBurner
/// @notice Burns unsold BWLK from the Uniswap CCA launch.
contract UnsoldBurner {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable BWLK;

    event Burned(address indexed caller, uint256 amount);

    error ZeroAddress();
    error NothingToBurn();

    constructor(
        address bwlk
    ) {
        if (bwlk == address(0)) revert ZeroAddress();
        BWLK = IERC20(bwlk);
    }

    /// @notice Sweep the auction's unsold BWLK into this contract, then burn the whole balance.
    function sweep(
        address auction
    ) external {
        if (auction.code.length != 0) {
            // solhint-disable-next-line no-empty-blocks
            try ICcaAuction(auction).sweepUnsoldTokens() {} catch {}
        }
        uint256 balance = BWLK.balanceOf(address(this));
        if (balance != 0) _burn(balance);
    }

    /// @notice Burn the contract's entire BWLK balance. Reverts if there is nothing to burn.
    function burn() external {
        uint256 balance = BWLK.balanceOf(address(this));
        if (balance == 0) revert NothingToBurn();
        _burn(balance);
    }

    function _burn(
        uint256 amount
    ) private {
        BWLK.safeTransfer(DEAD, amount);
        emit Burned(msg.sender, amount);
    }
}

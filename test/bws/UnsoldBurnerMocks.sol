// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUnsoldBurner} from "src/interfaces/IUnsoldBurner.sol";

/// @notice Mintable ERC20 for the UnsoldBurner tests.
contract MockERC20 is ERC20 {
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @notice CCA sweep stand-in matching the parts UnsoldBurner uses: pull-only (gated to tokensRecipient),
///         one-shot, pushes its balance to the recipient. Fund it with the unsold amount (the full offered
///         supply for a non-graduated auction, or the remainder for a graduated one).
contract MockCcaAuction {
    using SafeERC20 for IERC20;

    error NotAuthorized(address authorized, address caller);
    error CannotSweepTokens();

    event TokensSwept(address indexed tokensRecipient, uint256 tokensAmount);

    IERC20 public immutable token;
    address public immutable tokensRecipient;
    uint256 public sweepUnsoldTokensBlock;
    /// @dev The offered supply (the real CCA's TOTAL_SUPPLY getter); settable for gate tests.
    uint128 public totalSupply;

    constructor(
        IERC20 _token,
        address _tokensRecipient
    ) {
        token = _token;
        tokensRecipient = _tokensRecipient;
    }

    function setTotalSupply(
        uint128 supply
    ) external {
        totalSupply = supply;
    }

    function sweepUnsoldTokens() external {
        if (msg.sender != tokensRecipient) revert NotAuthorized(tokensRecipient, msg.sender);
        if (sweepUnsoldTokensBlock != 0) revert CannotSweepTokens();
        sweepUnsoldTokensBlock = block.number == 0 ? 1 : block.number;
        uint256 amount = token.balanceOf(address(this));
        if (amount != 0) token.safeTransfer(tokensRecipient, amount);
        emit TokensSwept(tokensRecipient, amount);
    }
}

/// @notice `sweepUnsoldTokens()` always reverts, to exercise the burner swallowing a reverting call.
contract RevertingCcaAuction {
    error AlwaysReverts();

    function sweepUnsoldTokens() external pure {
        revert AlwaysReverts();
    }
}

/// @notice Reenters the burner during `sweepUnsoldTokens()` to check reentrancy only triggers the same
///         terminal burn to DEAD.
contract ReentrantCcaAuction {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable burner;
    bool public reentered;

    constructor(
        IERC20 _token,
        address _burner
    ) {
        token = _token;
        burner = _burner;
    }

    function sweepUnsoldTokens() external {
        uint256 amount = token.balanceOf(address(this));
        if (amount != 0) token.safeTransfer(burner, amount);
        if (!reentered) {
            reentered = true;
            IUnsoldBurner(burner).burn(); // reenter mid-sweep
        }
    }
}

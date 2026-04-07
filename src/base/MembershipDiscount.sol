// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title MembershipDiscount - Shared NFT membership check and BPS discount helpers
/// @notice Abstract base inherited by contracts that offer fee discounts to Boardwalk NFT holders.
abstract contract MembershipDiscount {
    // ============ Constants ============

    uint256 internal constant MAX_DISCOUNT_BPS = 10_000;

    bytes32 public constant ACTION_SET_NFT_COLLECTION = keccak256("SET_NFT_COLLECTION");

    // ============ State ============

    address public nftCollection;

    // ============ Events ============

    event NftCollectionChanged(address oldCollection, address newCollection);

    // ============ Internal Functions ============

    /// @dev Returns true when `account` holds at least one NFT. Returns false when disabled (address(0)).
    function _isMember(
        address account
    ) internal view returns (bool) {
        address nft = nftCollection;
        if (nft == address(0)) return false;
        return IERC721(nft).balanceOf(account) > 0;
    }

    /// @dev Applies a BPS discount to `baseCost` when the caller is a member.
    ///      Returns `baseCost` unchanged for non-members, zero base cost, or when `discountBps == 0`.
    function _effectiveCost(
        uint256 baseCost,
        uint256 discountBps,
        address account
    ) internal view returns (uint256) {
        if (baseCost == 0 || discountBps == 0 || !_isMember(account)) return baseCost;
        return baseCost - (baseCost * discountBps / MAX_DISCOUNT_BPS);
    }

    /// @dev Sets the NFT collection address. Pass address(0) to disable discounts.
    function _setNftCollection(
        address _nft
    ) internal {
        emit NftCollectionChanged(nftCollection, _nft);
        nftCollection = _nft;
    }
}

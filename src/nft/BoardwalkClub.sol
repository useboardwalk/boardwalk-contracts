// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

/// @title BoardwalkClub
/// @notice Soulbound membership NFT minted on non-Base chains to mirror Boardwalk Club.
contract BoardwalkClub is ERC721, ERC721Enumerable, Ownable2Step {
    uint256 public nextTokenId;

    error NonTransferable();

    constructor(
        address initialOwner
    ) ERC721("Boardwalk Club", "BC") Ownable(initialOwner) {}

    /// @notice Every token shares one metadata URI 
    /// @dev    Mirrors the Base SeaDrop collection.
    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        _requireOwned(tokenId);
        return "ipfs://bafkreihqzbvqdrajswauuypexczvjfwe4ii7jdxbaujfoz7mnqp3h62ud4";
    }

    /// @notice Mint a membership.
    function mint(
        address to
    ) external onlyOwner returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _mint(to, tokenId);
    }

    /// @notice Batch mint memberships.
    function batchMint(
        address[] calldata recipients
    ) external onlyOwner {
        uint256 len = recipients.length;
        uint256 id = nextTokenId;
        for (uint256 i; i < len; ++i) {
            _mint(recipients[i], id++);
        }
        nextTokenId = id;
    }

    /// @dev Soulbound: transfers revert.
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721, ERC721Enumerable) returns (address) {
        if (_ownerOf(tokenId) != address(0)) revert NonTransferable();
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(
        address account,
        uint128 value
    ) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

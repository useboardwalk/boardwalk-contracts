// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {BoardwalkClubBridgeBase} from "./BoardwalkClubBridgeBase.sol";

/// @title BoardwalkClubMirror
/// @notice Spoke-chain Boardwalk Club, backed 1:1 by originals locked in the Base lockbox.
///         Mints on inbound messages, burns to bridge back. Standard transferable ERC721 with the
///         original's ids and metadata.
contract BoardwalkClubMirror is ERC721, BoardwalkClubBridgeBase {
    /// @notice CCIP chain selector of Base, the only chain this mirror talks to.
    uint64 public immutable BASE_CHAIN_SELECTOR;

    error OnlyBaseSelector();
    error NotTokenOwner();

    constructor(
        address router,
        address initialOwner,
        uint64 baseChainSelector,
        address lockbox
    ) ERC721("Boardwalk Beach Club", "BBC") BoardwalkClubBridgeBase(router, initialOwner) {
        if (baseChainSelector == 0) revert ZeroSelector();
        if (lockbox == address(0)) revert ZeroAddress();
        BASE_CHAIN_SELECTOR = baseChainSelector;
        peers[baseChainSelector] = lockbox;
        emit PeerSet(baseChainSelector, lockbox);
    }

    /// @notice ERC165 for ERC721, ERC721Metadata, and IAny2EVMMessageReceiver.
    /// @dev    Must be `pure` to override CCIPReceiver's, so the ids are spelled out instead of
    ///         calling the ERC721 super. Returning false for `0x85572ffb` would make the offramp
    ///         skip `ccipReceive` and mark deliveries successful without minting; a parity test
    ///         keeps the list honest.
    function supportsInterface(
        bytes4 interfaceId
    ) public pure override(ERC721, CCIPReceiver) returns (bool) {
        return interfaceId == 0x80ac58cd // type(IERC721).interfaceId
            || interfaceId == 0x5b5e139f // type(IERC721Metadata).interfaceId
            || interfaceId == 0x01ffc9a7 // type(IERC165).interfaceId
            || interfaceId == 0x85572ffb; // type(IAny2EVMMessageReceiver).interfaceId
    }

    /// @dev Matches the original SeaDrop collection's URIs: baseURI + tokenId, no suffix.
    function _baseURI() internal pure override returns (string memory) {
        return "ipfs://QmZrgwLmT1mSRokf2ohxuVeao3zVYYLN2AS6ds5PswXCiZ/";
    }

    /// @dev Peers can only ever point at Base.
    function _validatePeerSelector(
        uint64 chainSelector
    ) internal view override {
        if (chainSelector != BASE_CHAIN_SELECTOR) revert OnlyBaseSelector();
    }

    /// @dev Owner-only burn; OZ v5 `_burn` skips auth, so the check is explicit.
    function _lockOrBurn(
        address from,
        uint256 tokenId
    ) internal override {
        if (_ownerOf(tokenId) != from) revert NotTokenOwner();
        _burn(tokenId);
    }

    /// @dev `_mint`.
    function _releaseOrMint(
        address to,
        uint256 tokenId
    ) internal override {
        _mint(to, tokenId);
    }

    /// @dev Destination executes an ERC721A SeaDrop `transferFrom` release on Base.
    function _destGasLimit() internal pure override returns (uint256) {
        return 250_000;
    }
}

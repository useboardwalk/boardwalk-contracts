// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {BoardwalkClubBridgeBase} from "./BoardwalkClubBridgeBase.sol";

/// @title BoardwalkClubLockbox
/// @notice Base-chain side of the Boardwalk Club bridge. Locks originals from the immutable
///         SeaDrop collection when a holder bridges out; releases them when the spoke mirror
///         burns its representation back.
contract BoardwalkClubLockbox is BoardwalkClubBridgeBase {
    bytes32 public constant ACTION_RESCUE = keccak256("RESCUE");
    bytes32 public constant ACTION_FORCE_UNLOCK = keccak256("FORCE_UNLOCK");
    uint256 public constant FORCE_UNLOCK_DELAY = 30 days;

    /// @notice The original Boardwalk Club collection (SeaDrop).
    IERC721 public immutable NFT;

    /// @notice True while `tokenId` is locked against a live spoke representation.
    mapping(uint256 => bool) public locked;

    /// @notice One-shot latch for `initializePeers`.
    bool public peersInitialized;

    error NotAContract();
    error AlreadyInitialized();
    error EmptyArray();
    error ArrayLengthMismatch();
    error DuplicateSelector(uint64 chainSelector);
    error TokenNotLocked(uint256 tokenId);
    error TokenIsLocked(uint256 tokenId);

    event PeersInitialized();
    event Rescued(address indexed collection, uint256 indexed tokenId, address indexed to);
    event ForceUnlocked(uint256 indexed tokenId, address indexed to);

    constructor(
        address router,
        address initialOwner,
        address nft
    ) BoardwalkClubBridgeBase(router, initialOwner) {
        if (nft.code.length == 0) revert NotAContract();
        NFT = IERC721(nft);
    }

    /// @notice One-shot initial wiring. Mirrors deploy after the lockbox, so all spoke addresses
    ///         are known here; later changes go through the 7-day timelock.
    /// @param selectors CCIP chain selectors of the spoke chains.
    /// @param peerAddrs Mirror address on each spoke, index-aligned with `selectors`.
    function initializePeers(
        uint64[] calldata selectors,
        address[] calldata peerAddrs
    ) external onlyOwner {
        if (peersInitialized) revert AlreadyInitialized();
        uint256 len = selectors.length;
        if (len == 0) revert EmptyArray();
        if (peerAddrs.length != len) revert ArrayLengthMismatch();

        peersInitialized = true;

        for (uint256 i = 0; i < len;) {
            uint64 selector = selectors[i];
            address peer = peerAddrs[i];
            if (selector == 0) revert ZeroSelector();
            if (peer == address(0)) revert ZeroAddress();
            if (peers[selector] != address(0)) revert DuplicateSelector(selector);

            peers[selector] = peer;
            emit PeerSet(selector, peer);

            unchecked {
                ++i;
            }
        }

        emit PeersInitialized();
    }

    /// @notice Signal release of an asset the lockbox holds outside lock accounting, e.g. an
    ///         NFT transferred in directly instead of via `bridge`. Any collection. 7-day delay.
    /// @dev    Locked originals are excluded: `executeRescue` reverts on `locked` ids.
    function signalRescue(
        address collection,
        uint256 tokenId,
        address to
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _signal(keccak256(abi.encode(ACTION_RESCUE, collection, tokenId)), keccak256(abi.encode(to)));
    }

    /// @notice Execute a pending release. Permissionless after the delay.
    function executeRescue(
        address collection,
        uint256 tokenId,
        address to
    ) external {
        if (collection == address(NFT) && locked[tokenId]) revert TokenIsLocked(tokenId);
        _execute(keccak256(abi.encode(ACTION_RESCUE, collection, tokenId)), keccak256(abi.encode(to)));
        IERC721(collection).transferFrom(address(this), to, tokenId);
        emit Rescued(collection, tokenId, to);
    }

    /// @notice Cancel a pending release.
    function cancelRescue(
        address collection,
        uint256 tokenId
    ) external onlyOwner {
        _cancel(keccak256(abi.encode(ACTION_RESCUE, collection, tokenId)));
    }

    /// @notice Signal release of an locked original whose spoke representation is gone
    ///         (delivery marked successful without executing, or a deprecated lane).
    /// @param tokenId The locked token to force-unlock.
    /// @param to Recipient.
    function signalForceUnlock(
        uint256 tokenId,
        address to
    ) external onlyOwner {
        if (!locked[tokenId]) revert TokenNotLocked(tokenId);
        if (to == address(0)) revert ZeroAddress();
        _signal(keccak256(abi.encode(ACTION_FORCE_UNLOCK, tokenId)), keccak256(abi.encode(to)), FORCE_UNLOCK_DELAY);
    }

    /// @notice Execute a pending force-unlock. Permissionless after the delay.
    function executeForceUnlock(
        uint256 tokenId,
        address to
    ) external {
        if (!locked[tokenId]) revert TokenNotLocked(tokenId);
        _execute(keccak256(abi.encode(ACTION_FORCE_UNLOCK, tokenId)), keccak256(abi.encode(to)));
        delete locked[tokenId];
        NFT.transferFrom(address(this), to, tokenId);
        emit ForceUnlocked(tokenId, to);
    }

    /// @notice Cancel a pending force-unlock.
    function cancelForceUnlock(
        uint256 tokenId
    ) external onlyOwner {
        _cancel(keccak256(abi.encode(ACTION_FORCE_UNLOCK, tokenId)));
    }

    /// @dev Accounting first, then pull. Passing `from = caller` makes bridging owner-only;
    ///      the caller must have approved the lockbox.
    function _lockOrBurn(
        address from,
        uint256 tokenId
    ) internal override {
        locked[tokenId] = true;
        NFT.transferFrom(from, address(this), tokenId);
    }

    /// @dev A message can only release what `bridge` locked. Plain `transferFrom`: no receiver
    ///      callback inside the CCIP delivery. Cancels any pending force-unlock so a matured
    ///      signal cannot fire against a later re-lock.
    function _releaseOrMint(
        address to,
        uint256 tokenId
    ) internal override {
        if (!locked[tokenId]) revert TokenNotLocked(tokenId);
        delete locked[tokenId];
        bytes32 forceUnlockKey = keccak256(abi.encode(ACTION_FORCE_UNLOCK, tokenId));
        if (pendingChanges[forceUnlockKey].signalTime != 0) _cancel(forceUnlockKey);
        NFT.transferFrom(address(this), to, tokenId);
    }

    /// @dev Destination executes an OZ `_mint` on the mirror.
    function _destGasLimit() internal pure override returns (uint256) {
        return 200_000;
    }
}

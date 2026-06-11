// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {Timelocked} from "../base/Timelocked.sol";

/// @title BoardwalkClubBridgeBase
/// @notice Shared CCIP plumbing for bridging Boardwalk Club memberships between Base and the
///         spoke chains. Every lane has Base on one end. Concrete sides implement the token
///         operation: lock/release (lockbox) or burn/mint (mirror).
abstract contract BoardwalkClubBridgeBase is Ownable2Step, Timelocked, CCIPReceiver {
    bytes32 public constant ACTION_SET_PEER = keccak256("SET_PEER");

    /// @notice Trusted bridge contract on each chain, keyed by CCIP chain selector.
    mapping(uint64 => address) public peers;

    error ZeroAddress();
    error ZeroSelector();
    error NotAuthorized();
    error NoPeer(uint64 chainSelector);
    error InvalidRecipient(address recipient);
    error InsufficientFee(uint256 required, uint256 provided);
    error RefundFailed();
    error InvalidPeer(uint64 chainSelector, address sender);
    error RenounceDisabled();

    event PeerSet(uint64 indexed chainSelector, address indexed peer);
    event BridgeInitiated(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed from,
        address to,
        uint256 tokenId,
        uint256 fee
    );
    event BridgeReceived(
        bytes32 indexed messageId, uint64 indexed sourceChainSelector, address indexed to, uint256 tokenId
    );

    constructor(
        address router,
        address initialOwner
    ) CCIPReceiver(router) Ownable(initialOwner) {}

    /// @notice Bridge `tokenId` to `recipient` on the destination chain. Caller must own the
    ///         token and pay the CCIP fee in native; excess is refunded.
    /// @param destinationChainSelector CCIP selector of the destination chain.
    /// @param tokenId The membership token to bridge.
    /// @param recipient Receiver on the destination chain.
    /// @return messageId The CCIP message id.
    function bridge(
        uint64 destinationChainSelector,
        uint256 tokenId,
        address recipient
    ) external payable returns (bytes32 messageId) {
        if (recipient == address(0)) revert ZeroAddress();
        address peer = peers[destinationChainSelector];
        if (peer == address(0)) revert NoPeer(destinationChainSelector);
        if (recipient == peer || recipient == address(this)) revert InvalidRecipient(recipient);

        _lockOrBurn(msg.sender, tokenId);

        Client.EVM2AnyMessage memory message = _buildMessage(peer, recipient, tokenId);
        IRouterClient router = IRouterClient(getRouter());
        uint256 fee = router.getFee(destinationChainSelector, message);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);

        messageId = router.ccipSend{value: fee}(destinationChainSelector, message);

        emit BridgeInitiated(messageId, destinationChainSelector, msg.sender, recipient, tokenId, fee);

        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @notice The native fee `bridge` would require right now, using the same message shape.
    function quoteBridge(
        uint64 destinationChainSelector,
        uint256 tokenId,
        address recipient
    ) external view returns (uint256 fee) {
        address peer = peers[destinationChainSelector];
        if (peer == address(0)) revert NoPeer(destinationChainSelector);
        return IRouterClient(getRouter()).getFee(destinationChainSelector, _buildMessage(peer, recipient, tokenId));
    }

    /// @notice Signal a peer change for `chainSelector`. 7-day delay, 7-day execute window.
    function signalSetPeer(
        uint64 chainSelector,
        address newPeer
    ) external onlyOwner {
        if (chainSelector == 0) revert ZeroSelector();
        if (newPeer == address(0)) revert ZeroAddress();
        _validatePeerSelector(chainSelector);
        _signal(keccak256(abi.encode(ACTION_SET_PEER, chainSelector)), keccak256(abi.encode(newPeer)));
    }

    /// @notice Execute a pending peer change. Permissionless after the delay; `newPeer` must
    ///         match the signaled value.
    function executeSetPeer(
        uint64 chainSelector,
        address newPeer
    ) external {
        if (chainSelector == 0) revert ZeroSelector();
        if (newPeer == address(0)) revert ZeroAddress();
        _validatePeerSelector(chainSelector);
        _execute(keccak256(abi.encode(ACTION_SET_PEER, chainSelector)), keccak256(abi.encode(newPeer)));
        peers[chainSelector] = newPeer;
        emit PeerSet(chainSelector, newPeer);
    }

    /// @notice Cancel a pending peer change for `chainSelector`.
    function cancelSetPeer(
        uint64 chainSelector
    ) external onlyOwner {
        _cancel(keccak256(abi.encode(ACTION_SET_PEER, chainSelector)));
    }

    /// @notice Clears the peer, blocking the lane in both directions.
    /// @dev Inbound messages park in CCIP's failed state and can be re-executed once the peer is
    ///      restored.
    function removePeer(
        uint64 chainSelector
    ) external onlyOwner {
        delete peers[chainSelector];
        emit PeerSet(chainSelector, address(0));
    }

    /// @dev Only the registered peer for the source chain is honored.
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        address sender = abi.decode(message.sender, (address));
        address peer = peers[message.sourceChainSelector];
        if (peer == address(0) || sender != peer) revert InvalidPeer(message.sourceChainSelector, sender);

        (address to, uint256 tokenId) = abi.decode(message.data, (address, uint256));
        _releaseOrMint(to, tokenId);

        emit BridgeReceived(message.messageId, message.sourceChainSelector, to, tokenId);
    }

    /// @dev 64-byte payload, native fee token, out-of-order execution
    function _buildMessage(
        address peer,
        address recipient,
        uint256 tokenId
    ) internal view returns (Client.EVM2AnyMessage memory) {
        return Client.EVM2AnyMessage({
            receiver: abi.encode(peer),
            data: abi.encode(recipient, tokenId),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.GenericExtraArgsV2({gasLimit: _destGasLimit(), allowOutOfOrderExecution: true})
            ),
            feeToken: address(0)
        });
    }

    /// @dev Closes the generic Timelocked path, including burns; only the typed actions above
    ///      exist.
    function _authAdmin(
        bytes32
    ) internal pure override {
        revert NotAuthorized();
    }

    /// @dev Lets a concrete side restrict which selectors may hold a peer.
    function _validatePeerSelector(
        uint64 chainSelector
    ) internal view virtual {}

    /// @dev Source-side effect: lock (lockbox) or burn (mirror).
    function _lockOrBurn(
        address from,
        uint256 tokenId
    ) internal virtual;

    /// @dev Destination-side effect: release (lockbox) or mint (mirror).
    function _releaseOrMint(
        address to,
        uint256 tokenId
    ) internal virtual;

    /// @dev Gas limit for executing `_releaseOrMint` on the destination chain.
    function _destGasLimit() internal pure virtual returns (uint256);
}

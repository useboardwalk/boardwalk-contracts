// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BoardwalkClubLockbox} from "src/nft/BoardwalkClubLockbox.sol";
import {BoardwalkClubMirror} from "src/nft/BoardwalkClubMirror.sol";
import {CCIPConfig} from "script/CCIPConfig.sol";

/// @title DeployNFTBridge
/// @notice Deploys the Boardwalk Club bridge: the lockbox on Base, a mirror on each spoke
///         (Ethereum, Arbitrum, Robinhood).
/// @dev The Base lockbox and the Ethereum/Arbitrum mirrors are already live; in practice this
///      script now only deploys a mirror on a NEW spoke (e.g. Robinhood). Runbook for a new spoke:
///      1. Spoke: run with LOCKBOX_ADDRESS set. The mirror wires its Base peer in the
///         constructor; no post-deploy call needed.
///      2. Base: the lockbox's one-shot `initializePeers` is consumed, so wire the new spoke via
///         script/05_AddLockboxPeer.s.sol (typed SET_PEER, 7-day timelock: signal, wait, execute).
///      3. Canary round-trip on the new lane with a team-held token before any announcement. A
///         mis-wired peer is not a revert but a delivery marked successful without executing
///         (see lockbox NatSpec); the canary is the only check that catches it.
///      4. transferOwnership (2-step) of the mirror to the multisig.
///      5. On the spoke, point gating at the mirror via the existing timelocks: LaunchFactory and
///         BoostBurn `signalAction(ACTION_SET_NFT_COLLECTION, keccak256(abi.encode(mirror)))`,
///         wait 7 days, `executeSetNftCollection(mirror)`. Base keeps the original collection.
///      Peer migration: never re-point a live peer without draining the lane. `removePeer` the
///      outgoing side when you signal (the lane drains during the 7-day delay; execute is
///      permissionless after it), wait out in-flight deliveries, then execute.
contract DeployNFTBridge is Script {
    /// @dev Original Boardwalk Club SeaDrop collection on Base.
    address internal constant BBC_COLLECTION = 0xcc2AAF39960445ab981aA07ccB3947718635F39E;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        // Deployer stays initial owner through the wiring stage (05_AddLockboxPeer's SET_PEER
        // signal is owner-gated and takes the 7-day timelock either way); ownership moves to the
        // multisig (2-step) after the canary round-trips.
        address owner = vm.envOr("OWNER", deployer);
        require(owner != address(0), "OWNER required");

        (address router, uint64 chainSelector) = CCIPConfig.resolve(block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Boardwalk NFT Bridge Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Owner:", owner);
        console.log("Chain id:", block.chainid);
        console.log("CCIP router:", router);
        console.log("CCIP selector:", chainSelector);

        if (block.chainid == CCIPConfig.CHAIN_BASE) {
            BoardwalkClubLockbox lockbox = new BoardwalkClubLockbox(router, owner, BBC_COLLECTION);
            console.log("BoardwalkClubLockbox:", address(lockbox));
        } else {
            address lockboxAddr = vm.envAddress("LOCKBOX_ADDRESS");
            require(lockboxAddr != address(0), "LOCKBOX_ADDRESS required");

            BoardwalkClubMirror mirror = new BoardwalkClubMirror(router, owner, CCIPConfig.SELECTOR_BASE, lockboxAddr);
            console.log("BoardwalkClubMirror:", address(mirror));
            require(mirror.peers(CCIPConfig.SELECTOR_BASE) == lockboxAddr, "mirror peer mismatch");
        }

        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BoardwalkClubLockbox} from "src/nft/BoardwalkClubLockbox.sol";
import {BoardwalkClubMirror} from "src/nft/BoardwalkClubMirror.sol";
import {CCIPConfig} from "script/CCIPConfig.sol";

/// @title DeployNFTBridge
/// @notice Deploys the Boardwalk Club bridge: the lockbox on Base, a mirror on each spoke
///         (Ethereum, Katana, Ink, Fraxtal).
/// @dev Runbook:
///      1. Base: run this script. Peers start empty, so `bridge` reverts `NoPeer` and nothing
///         can enter custody before step 3.
///      2. Each spoke: rerun with LOCKBOX_ADDRESS set. The mirror wires its Base peer in the
///         constructor; no post-deploy call needed.
///      3. Base: run script/05_WireLockboxPeers.s.sol with the four MIRROR_* addresses.
///      4. Canary round-trip per lane with a team-held token before any announcement. A
///         mis-wired peer is not a revert but a delivery marked successful without executing
///         (see lockbox NatSpec); the canary is the only check that catches it.
///      5. transferOwnership (2-step) of all five contracts to the multisig.
///      6. Per spoke, re-point gating via the existing timelocks: LaunchFactory and BoostBurn
///         `signalAction(ACTION_SET_NFT_COLLECTION, keccak256(abi.encode(mirror)))`, wait 7
///         days, `executeSetNftCollection(mirror)`. Base keeps the original collection.
///      Peer migration: never re-point a live peer without draining the lane. `removePeer` the
///      outgoing side when you signal (the lane drains during the 7-day delay; execute is
///      permissionless after it), wait out in-flight deliveries, then execute.
contract DeployNFTBridge is Script {
    /// @dev Original Boardwalk Club SeaDrop collection on Base.
    address internal constant BBC_COLLECTION = 0xcc2AAF39960445ab981aA07ccB3947718635F39E;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        // Deployer stays initial owner so 05_WireLockboxPeers can wire peers without a timelock;
        // ownership moves to the multisig (2-step) after the canary round-trips.
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

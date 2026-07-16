// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BoardwalkClubLockbox} from "src/nft/BoardwalkClubLockbox.sol";
import {CCIPConfig} from "script/CCIPConfig.sol";

/// @title AddLockboxPeer
/// @notice Wires one new spoke mirror into the live Base lockbox via the typed SET_PEER timelock.
///         The lockbox's one-shot `initializePeers` was consumed at the original deploy, so every
///         new spoke (e.g. Robinhood) goes through signal → 7-day delay → execute. Run on Base
///         only; the broadcaster must be the lockbox owner for the signal step (execute is
///         permissionless after the delay).
/// @dev Env: LOCKBOX_ADDRESS, SPOKE_CHAIN_ID (the spoke's evm chain id, resolved to its CCIP
///      selector via CCIPConfig), MIRROR (the spoke's deployed BoardwalkClubMirror), and
///      PEER_STEP = "signal" | "execute". After execute, canary round-trip the lane with a
///      team-held token before any announcement — a mis-wired peer is not a revert but a delivery
///      marked successful without executing (see lockbox NatSpec).
contract AddLockboxPeer is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(block.chainid == CCIPConfig.CHAIN_BASE, "run on Base");

        BoardwalkClubLockbox lockbox = BoardwalkClubLockbox(vm.envAddress("LOCKBOX_ADDRESS"));
        uint256 spokeChainId = vm.envUint("SPOKE_CHAIN_ID");
        address mirror = vm.envAddress("MIRROR");
        string memory step = vm.envString("PEER_STEP");

        require(spokeChainId != CCIPConfig.CHAIN_BASE, "spoke cannot be Base");
        require(mirror != address(0), "MIRROR required");
        (, uint64 spokeSelector) = CCIPConfig.resolve(spokeChainId);

        console.log("=== Lockbox SET_PEER ===");
        console.log("Lockbox:", address(lockbox));
        console.log("Spoke chain id:", spokeChainId);
        console.log("Spoke selector:", spokeSelector);
        console.log("Mirror:", mirror);
        console.log("Step:", step);

        vm.startBroadcast(deployerPrivateKey);
        if (keccak256(bytes(step)) == keccak256("signal")) {
            lockbox.signalSetPeer(spokeSelector, mirror);
            console.log("Signaled. Execute after the 7-day delay (within the expiry window).");
        } else if (keccak256(bytes(step)) == keccak256("execute")) {
            lockbox.executeSetPeer(spokeSelector, mirror);
            require(lockbox.peers(spokeSelector) == mirror, "peer readback mismatch");
            // The real router must quote the lane; catches a selector typo'd to a dead lane.
            // It does not validate the mirror address — only the canary round-trip does.
            require(lockbox.quoteBridge(spokeSelector, 1, mirror) > 0, "lane not quotable");
            console.log("Peer wired and lane quotable. Run the canary round-trip next.");
        } else {
            revert("PEER_STEP must be 'signal' or 'execute'");
        }
        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BoardwalkClubLockbox} from "src/nft/BoardwalkClubLockbox.sol";
import {CCIPConfig} from "script/CCIPConfig.sol";

/// @title WireLockboxPeers
/// @notice One-shot wiring of the Base lockbox to the four spoke mirrors. Run on Base only,
///         after 04_DeployNFTBridge has run on all five chains; the broadcaster must be the
///         lockbox owner. Every peer is read back and verified before the script exits.
contract WireLockboxPeers is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(block.chainid == CCIPConfig.CHAIN_BASE, "run on Base");

        BoardwalkClubLockbox lockbox = BoardwalkClubLockbox(vm.envAddress("LOCKBOX_ADDRESS"));

        uint64[] memory selectors = new uint64[](4);
        address[] memory mirrors = new address[](4);
        selectors[0] = CCIPConfig.SELECTOR_ETHEREUM;
        mirrors[0] = vm.envAddress("MIRROR_ETHEREUM");
        selectors[1] = CCIPConfig.SELECTOR_KATANA;
        mirrors[1] = vm.envAddress("MIRROR_KATANA");
        selectors[2] = CCIPConfig.SELECTOR_INK;
        mirrors[2] = vm.envAddress("MIRROR_INK");
        selectors[3] = CCIPConfig.SELECTOR_FRAXTAL;
        mirrors[3] = vm.envAddress("MIRROR_FRAXTAL");

        vm.startBroadcast(deployerPrivateKey);
        lockbox.initializePeers(selectors, mirrors);
        vm.stopBroadcast();

        for (uint256 i = 0; i < 4; ++i) {
            require(lockbox.peers(selectors[i]) == mirrors[i], "peer readback mismatch");
            // The real router must quote the lane; catches a selector typo'd to a dead lane.
            // It does not validate the mirror address — only the canary round-trip does.
            require(lockbox.quoteBridge(selectors[i], 1, mirrors[i]) > 0, "lane not quotable");
            console.log("Peer wired and lane quotable, selector:", selectors[i]);
            console.log("  mirror:", mirrors[i]);
        }
        require(lockbox.peersInitialized(), "init latch not set");
        console.log("Lockbox peers initialized.");
    }
}

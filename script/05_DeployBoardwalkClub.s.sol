// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BoardwalkClub} from "src/nft/BoardwalkClub.sol";

/// @title DeployBoardwalkClub - Deploy the soulbound membership NFT
/// @notice Deploys BoardwalkClub, optionally airdrops an initial list, and prints the NFT_COLLECTION
///         address to wire into LaunchFactory/BoostBurn.
/// @dev Env: DEPLOYER_PRIVATE_KEY (required); OWNER (default deployer); MINT_RECIPIENTS
///      (comma-separated addresses for the initial airdrop).
contract DeployBoardwalkClub is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address owner = vm.envOr("OWNER", deployer);
        address[] memory recipients = vm.envOr("MINT_RECIPIENTS", ",", new address[](0));

        require(owner != address(0), "OWNER required");

        vm.startBroadcast(deployerPrivateKey);

        BoardwalkClub nft = new BoardwalkClub(owner);

        if (recipients.length > 0) {
            require(owner == deployer, "MINT_RECIPIENTS requires OWNER == deployer");
            nft.batchMint(recipients);
        }

        console.log("=== BoardwalkClub (soulbound) Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Owner:", owner);
        console.log("BoardwalkClub:", address(nft));
        console.log("NFT_COLLECTION:", address(nft));
        console.log("Initial airdrop count:", recipients.length);

        vm.stopBroadcast();

        console.log("\n=== Verification ===");
        require(nft.owner() == owner, "Owner mismatch");
        require(nft.totalSupply() == recipients.length, "Airdrop count mismatch");
        console.log("All verifications passed");
    }
}

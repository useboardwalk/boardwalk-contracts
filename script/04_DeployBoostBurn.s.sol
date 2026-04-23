// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BoostBurn} from "src/core/BoostBurn.sol";

/// @title DeployBoostBurn - Deploy the community-driven token ranking contract
/// @notice Deploys BoostBurn with configurable epoch parameters.
///         BoostBurn allows wallets to boost/deboost token rankings by burning BMX.
/// @dev Required env: DEPLOYER_PRIVATE_KEY, OWNER, BMX_ADDRESS. Optional: EPOCH_ZERO, EPOCH_DURATION, NFT_COLLECTION, MEMBER_BOOST_DISCOUNT_BPS.
contract DeployBoostBurn is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envOr("OWNER", vm.addr(deployerPrivateKey));
        address bmx = vm.envAddress("BMX_ADDRESS");

        uint256 epochZero = vm.envOr("EPOCH_ZERO", block.timestamp);
        uint256 epochDuration = vm.envOr("EPOCH_DURATION", uint256(30 days));

        require(owner != address(0), "OWNER required");
        require(bmx != address(0), "BMX_ADDRESS required");
        require(epochDuration > 0, "EPOCH_DURATION must be > 0");

        vm.startBroadcast(deployerPrivateKey);

        address nftCollection = vm.envOr("NFT_COLLECTION", address(0));
        uint256 memberBoostDiscountBps = vm.envOr("MEMBER_BOOST_DISCOUNT_BPS", uint256(10_000));

        BoostBurn boostBurn = new BoostBurn(owner, bmx, epochZero, epochDuration, nftCollection, memberBoostDiscountBps);

        console.log("=== BoostBurn Deployment ===");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("Owner:", owner);
        console.log("BMX:", bmx);
        console.log("Epoch Zero:", epochZero);
        console.log("Epoch Duration:", epochDuration);
        console.log("BoostBurn:", address(boostBurn));

        vm.stopBroadcast();

        // Post-deployment verification
        console.log("\n=== Verification ===");
        require(boostBurn.owner() == owner, "Owner mismatch");
        require(boostBurn.BMX() == bmx, "BMX mismatch");
        require(boostBurn.EPOCH_ZERO() == epochZero, "EPOCH_ZERO mismatch");
        require(boostBurn.EPOCH_DURATION() == epochDuration, "EPOCH_DURATION mismatch");
        console.log("All verifications passed");
    }
}

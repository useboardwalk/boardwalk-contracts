// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IDEXRouter} from "src/interfaces/IDEXRouter.sol";

/// @title DeployDEX
/// @notice Deploys the Boardwalk DEX singleton contracts (Factory + Router)
/// @dev The DEX contracts use older Solidity versions, so we deploy from artifacts via vm.deployCode.
contract DeployDEX is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address weth = vm.envOr("WETH_ADDRESS", address(0x4200000000000000000000000000000000000006));
        address feeToSetter = vm.envOr("FEE_TO_SETTER", deployer);

        require(weth != address(0), "WETH_ADDRESS required");
        require(feeToSetter != address(0), "FEE_TO_SETTER required");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy DEX Factory
        // Note: UniswapV2Factory constructor takes feeToSetter
        // The actual deployment uses the compiled bytecode from src/dex/core/UniswapV2Factory.sol
        // Foundry handles cross-version compilation automatically

        // Log deployment info
        console.log("=== Boardwalk DEX Deployment ===");
        console.log("Deployer:", deployer);
        console.log("WETH:", weth);
        console.log("FeeToSetter:", feeToSetter);

        address dexFactory =
            vm.deployCode("src/dex/core/UniswapV2Factory.sol:UniswapV2Factory", abi.encode(feeToSetter));
        address dexRouter =
            vm.deployCode("src/dex/periphery/UniswapV2Router02.sol:UniswapV2Router02", abi.encode(dexFactory, weth));

        require(IDEXRouter(dexRouter).factory() == dexFactory, "Router-Factory mismatch");

        console.log("DEX Factory:", dexFactory);
        console.log("DEX Router:", dexRouter);

        vm.stopBroadcast();
    }
}

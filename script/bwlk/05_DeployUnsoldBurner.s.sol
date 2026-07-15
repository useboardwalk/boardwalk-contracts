// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnsoldBurner} from "src/token/UnsoldBurner.sol";
import {EthereumConfig} from "./EthereumConfig.sol";

/// @title DeployUnsoldBurner - Deploy the unsold-BWLK sink for the Uniswap CCA launch
/// @notice Deploys `UnsoldBurner(BWLK)`. Set it as the CCA auction's `tokensRecipient` so unsold BWLK (all of
///         it if the auction fails to graduate) is burned to DEAD. Run before creating the auction:
///         `tokensRecipient` is immutable once the launch tx lands.
/// @dev Required env: DEPLOYER_PRIVATE_KEY, BWLK_TOKEN (same env name as scripts 02-04). Optional:
///      CCA_REQUIRED_CURRENCY_RAISED (graduation threshold in raise-token wei; only echoed here — the
///      auction is created through the LiquidityLauncher flow, see 06_LaunchBwlkCca.s.sol).
contract DeployUnsoldBurner is Script {
    error WrongChain(uint256 chainId);
    error BwlkHasNoCode(address bwlk);
    error BwlkSupplyWrong(uint256 actual, uint256 expected);

    function run() public {
        if (block.chainid != EthereumConfig.ETHEREUM_CHAIN_ID) revert WrongChain(block.chainid);
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address bwlk = vm.envAddress("BWLK_TOKEN");
        // The burner's BWLK is immutable and the auction's tokensRecipient is immutable from the
        // launch tx: a wrong token here silently strands the unsold supply, so pin the real BWLK.
        if (bwlk.code.length == 0) revert BwlkHasNoCode(bwlk);
        uint256 supply = IERC20(bwlk).totalSupply();
        if (supply != EthereumConfig.TOTAL_SUPPLY) revert BwlkSupplyWrong(supply, EthereumConfig.TOTAL_SUPPLY);
        // Read-only echo of the graduation threshold so the runbook step is captured alongside the deploy.
        uint256 requiredRaised = vm.envOr("CCA_REQUIRED_CURRENCY_RAISED", uint256(0));

        vm.startBroadcast(deployerPrivateKey);
        UnsoldBurner burner = new UnsoldBurner(bwlk);
        vm.stopBroadcast();

        console.log("UnsoldBurner deployed to:", address(burner));
        console.log("  BWLK token:", address(burner.BWLK()));
        console.log("  DEAD sink:", burner.DEAD());
        console.log("");
        console.log("CCA-launch wiring (set at auction creation, both immutable thereafter):");
        console.log("  AuctionParameters.tokensRecipient       =", address(burner));
        console.log("  AuctionParameters.requiredCurrencyRaised =", requiredRaised);
        if (requiredRaised == 0) {
            console.log("  WARNING: CCA_REQUIRED_CURRENCY_RAISED unset -> a 0 threshold graduates on any raise.");
            console.log("           Set the agreed graduation floor before creating the auction.");
        }
        console.log("After the auction ends, anyone may call UnsoldBurner.sweep(auction) to pull + burn unsold BWLK.");
    }
}

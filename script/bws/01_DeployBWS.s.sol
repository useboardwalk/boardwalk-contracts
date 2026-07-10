// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BWS} from "src/token/BWS.sol";
import {BwsMigration} from "src/token/BwsMigration.sol";
import {ArbitrumConfig} from "./ArbitrumConfig.sol";

/// @title DeployBWS - Deploy the fixed-supply BWS token on Arbitrum and distribute its genesis buckets
/// @notice Mints the full 3,150,000 BWS to the deployer/escrow, then distributes:
///         - 438,932 BWS -> the CCA launch wallet (219,466 auction + 219,466 LP seed), and
///         - 2,711,068 BWS -> the Migrator IF its address is already known (else left in escrow for
///           script 03 to fund after the Migrator is deployed).
/// @dev Required env: DEPLOYER_PRIVATE_KEY, BWS_CCIP_ADMIN, CCA_WALLET.
///      Optional env: BWS_RECIPIENT (genesis recipient/escrow, default = deployer), MIGRATOR
///      (if set, the migration pool is sent here now; otherwise script 03 funds it). The MIGRATOR
///      fast-path only works when the migrator was pre-deployed against a precomputed address of
///      THIS BWS (CREATE/CREATE2) — the run reverts, by design, on any migrator bound to another
///      token. The normal order (01 then 03) leaves MIGRATOR unset.
contract DeployBWS is Script {
    using SafeERC20 for IERC20;

    error WrongChain(uint256 chainId);
    error MigratorHasNoCode(address migrator);
    error MigratorBwsMismatch(address migratorBws, address bws);

    function run() public {
        if (block.chainid != ArbitrumConfig.ARBITRUM_CHAIN_ID) revert WrongChain(block.chainid);
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address recipient = vm.envOr("BWS_RECIPIENT", deployer);
        address ccipAdmin = vm.envAddress("BWS_CCIP_ADMIN");
        address ccaWallet = vm.envAddress("CCA_WALLET");
        address migrator = vm.envOr("MIGRATOR", address(0));

        vm.startBroadcast(deployerPrivateKey);

        BWS bws = new BWS(recipient, ccipAdmin);
        console.log("BWS deployed to:", address(bws));
        console.log("  total supply:", bws.totalSupply());
        console.log("  genesis recipient/escrow:", recipient);
        console.log("  ccipAdmin (getCCIPAdmin):", bws.getCCIPAdmin());

        // The recipient distributes the genesis buckets. When the recipient is the broadcaster the
        // transfers happen here; otherwise this script only deploys and the escrow distributes manually.
        if (recipient == deployer) {
            IERC20(address(bws)).safeTransfer(ccaWallet, ArbitrumConfig.CCA_BUCKET);
            console.log("Sent CCA market-formation bucket to:", ccaWallet);
            console.log("  amount:", ArbitrumConfig.CCA_BUCKET);

            if (migrator != address(0)) {
                // A wrong MIGRATOR (a stale redeploy bound to an older BWS, or a typo) permanently
                // strands the pool: BwsMigration has no foreign-token rescue. Only fund a migrator
                // provably built against THIS token.
                if (migrator.code.length == 0) revert MigratorHasNoCode(migrator);
                address migratorBws = address(BwsMigration(migrator).BWS());
                if (migratorBws != address(bws)) revert MigratorBwsMismatch(migratorBws, address(bws));
                IERC20(address(bws)).safeTransfer(migrator, ArbitrumConfig.MIGRATION_POOL);
                console.log("Sent migration pool to Migrator:", migrator);
                console.log("  amount:", ArbitrumConfig.MIGRATION_POOL);
            } else {
                console.log("MIGRATOR unset: 2,711,068 BWS held in escrow; fund via script 03.");
            }
            console.log("Escrow BWS remaining:", IERC20(address(bws)).balanceOf(deployer));
        } else {
            console.log("BWS_RECIPIENT != deployer: distribute the CCA + migration buckets from escrow manually.");
        }

        vm.stopBroadcast();
    }
}

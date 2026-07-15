// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BWLK} from "src/token/BWLK.sol";
import {BwlkMigration} from "src/token/BwlkMigration.sol";
import {EthereumConfig} from "./EthereumConfig.sol";

/// @title DeployBWLK - Deploy the fixed-supply BWLK token on Arbitrum and distribute its genesis buckets
/// @notice Mints the full 3,150,000 BWLK to the deployer/escrow, then distributes:
///         - 315,000 BWLK -> the CCA launch wallet (157,500 sale + 157,500 LP seed),
///         - 2,711,068 BWLK -> the Migrator IF its address is already known (else left in escrow
///           for script 03 to fund after the Migrator is deployed), and
///         - 123,932 BWLK LP incentives -> stay in escrow until the incentives program is wired.
/// @dev Required env: DEPLOYER_PRIVATE_KEY, BWLK_CCIP_ADMIN, CCA_WALLET.
///      Optional env: BWLK_RECIPIENT (genesis recipient/escrow, default = deployer), MIGRATOR
///      (if set, the migration pool is sent here now; otherwise script 03 funds it). The MIGRATOR
///      fast-path only works when the migrator was pre-deployed against a precomputed address of
///      THIS BWLK (CREATE/CREATE2) — the run reverts, by design, on any migrator bound to another
///      token. The normal order (01 then 03) leaves MIGRATOR unset.
contract DeployBWLK is Script {
    using SafeERC20 for IERC20;

    error WrongChain(uint256 chainId);
    error MigratorHasNoCode(address migrator);
    error MigratorBwlkMismatch(address migratorBwlk, address bwlk);

    function run() public {
        if (block.chainid != EthereumConfig.ETHEREUM_CHAIN_ID) revert WrongChain(block.chainid);
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address recipient = vm.envOr("BWLK_RECIPIENT", deployer);
        address ccipAdmin = vm.envAddress("BWLK_CCIP_ADMIN");
        address ccaWallet = vm.envAddress("CCA_WALLET");
        address migrator = vm.envOr("MIGRATOR", address(0));

        vm.startBroadcast(deployerPrivateKey);

        BWLK bwlk = new BWLK(recipient, ccipAdmin);
        console.log("BWLK deployed to:", address(bwlk));
        console.log("  total supply:", bwlk.totalSupply());
        console.log("  genesis recipient/escrow:", recipient);
        console.log("  ccipAdmin (getCCIPAdmin):", bwlk.getCCIPAdmin());

        // The recipient distributes the genesis buckets. When the recipient is the broadcaster the
        // transfers happen here; otherwise this script only deploys and the escrow distributes manually.
        if (recipient == deployer) {
            IERC20(address(bwlk)).safeTransfer(ccaWallet, EthereumConfig.CCA_BUCKET);
            console.log("Sent CCA market-formation bucket to:", ccaWallet);
            console.log("  amount:", EthereumConfig.CCA_BUCKET);

            if (migrator != address(0)) {
                // A wrong MIGRATOR (a stale redeploy bound to an older BWLK, or a typo) permanently
                // strands the pool: BwlkMigration has no foreign-token rescue. Only fund a migrator
                // provably built against THIS token.
                if (migrator.code.length == 0) revert MigratorHasNoCode(migrator);
                address migratorBwlk = address(BwlkMigration(migrator).BWLK());
                if (migratorBwlk != address(bwlk)) revert MigratorBwlkMismatch(migratorBwlk, address(bwlk));
                IERC20(address(bwlk)).safeTransfer(migrator, EthereumConfig.MIGRATION_POOL);
                console.log("Sent migration pool to Migrator:", migrator);
                console.log("  amount:", EthereumConfig.MIGRATION_POOL);
            } else {
                console.log("MIGRATOR unset: 2,711,068 BWLK held in escrow; fund via script 03.");
            }
            console.log("Escrow BWLK remaining:", IERC20(address(bwlk)).balanceOf(deployer));
        } else {
            console.log("BWLK_RECIPIENT != deployer: distribute the CCA + migration buckets from escrow manually.");
        }

        vm.stopBroadcast();
    }
}

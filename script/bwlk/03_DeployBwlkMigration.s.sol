// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BwlkMigration} from "src/token/BwlkMigration.sol";
import {EthereumConfig} from "./EthereumConfig.sol";

/// @title DeployBwlkMigration - Deploy + bring up the BMX -> BWLK Migrator on Ethereum mainnet
/// @notice Deploys BwlkMigration owned by the 21-day governance timelock. When the broadcaster is the
///         owner (dry-run / bring-up) it also sets the one-shot snapshot merkle root and then funds
///         the 2,711,068 BWLK migration pool; when OWNER is the timelock it deploys only and prints
///         the root-first bring-up steps.
/// @dev Sequencing matters: the root must be set (and verified) BEFORE the pool is funded. A mis-set
///      root on an empty migrator is a cheap redeploy; a funded migrator locks the pool — 86% of the
///      fixed supply — until CLAIM_DEADLINE (sweepUnclaimed is deadline-gated), and no replacement
///      migrator could be funded meanwhile. The root is one-shot on-chain; corrections after go-live
///      flow only through `creditPoints`.
///
///      `setMerkleRoot` is `onlyOwner`. When OWNER == the broadcaster (dry-run / bring-up) this script
///      sets the root and then funds in the same broadcast. When OWNER is the timelock the script only
///      deploys and prints the follow-up steps: timelock sets + verifies the root, THEN the escrow
///      funds the pool. It never funds ahead of the root.
///
///      Required env: DEPLOYER_PRIVATE_KEY, BWLK_TOKEN, STAKED_BWLK_TRACKER, BONUS_BWLK_TRACKER,
///      FEE_BWLK_TRACKER, BN_BWLK, GOVERNANCE_VOTER, MERKLE_ROOT, OWNER (the 21-day timelock).
///      BMX_ADDRESS is required (no default: the Ethereum-side migration source is being
///      re-scoped). Optional env: CLAIM_DEADLINE (default now + 365 days).
contract DeployBwlkMigration is Script {
    using SafeERC20 for IERC20;

    error WrongChain(uint256 chainId);

    function run() public {
        if (block.chainid != EthereumConfig.ETHEREUM_CHAIN_ID) revert WrongChain(block.chainid);
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        // No default: a silently deployer-owned migrator would also take the set-root-now branch
        // below, committing the one-shot root from whatever the env happened to hold.
        address owner = vm.envAddress("OWNER");

        address bmx = vm.envAddress("BMX_ADDRESS");
        address bwlk = vm.envAddress("BWLK_TOKEN");
        address stakedBwlkTracker = vm.envAddress("STAKED_BWLK_TRACKER");
        address bonusBwlkTracker = vm.envAddress("BONUS_BWLK_TRACKER");
        address feeBwlkTracker = vm.envAddress("FEE_BWLK_TRACKER");
        address bnBwlk = vm.envAddress("BN_BWLK");
        address voter = vm.envAddress("GOVERNANCE_VOTER");
        bytes32 merkleRoot = vm.envBytes32("MERKLE_ROOT");
        uint256 claimDeadline = vm.envOr("CLAIM_DEADLINE", block.timestamp + 365 days);

        vm.startBroadcast(deployerPrivateKey);

        BwlkMigration migrator = new BwlkMigration(
            owner, bmx, bwlk, stakedBwlkTracker, bonusBwlkTracker, feeBwlkTracker, bnBwlk, voter, claimDeadline
        );
        console.log("BwlkMigration deployed to:", address(migrator));
        console.log("  owner (must be 21-day timelock):", owner);
        console.log("  claimDeadline:", claimDeadline);

        // Root BEFORE funding, always. A mis-set root on an empty migrator is a cheap redeploy, but a
        // funded migrator locks the pool until CLAIM_DEADLINE (sweepUnclaimed is deadline-gated).
        if (owner == deployer) {
            migrator.setMerkleRoot(merkleRoot);
            console.log("setMerkleRoot done (broadcaster is owner).");
            IERC20(bwlk).safeTransfer(address(migrator), EthereumConfig.MIGRATION_POOL);
            console.log("Funded migration pool:", EthereumConfig.MIGRATION_POOL);
        } else {
            // Timelock-owned: deploy only. Funding here would commit the pool ahead of the root and
            // foreclose the redeploy-on-bad-root recovery, so it is left to a later manual transfer.
            console.log("OWNER is the timelock: NOT funding yet. In order:");
            console.log("1. Timelock calls migrator.setMerkleRoot with the verified artifact root:");
            console.logBytes32(merkleRoot);
            console.log("2. Verify migrator.merkleRoot() matches the artifact.");
            console.log("3. Only then transfer the pool from escrow:", EthereumConfig.MIGRATION_POOL);
        }

        vm.stopBroadcast();

        _printRunbook(address(migrator), stakedBwlkTracker, bonusBwlkTracker, feeBwlkTracker, bnBwlk);
    }

    function _printRunbook(
        address migrator,
        address stakedBwlkTracker,
        address bonusBwlkTracker,
        address feeBwlkTracker,
        address bnBwlk
    ) internal pure {
        console.log("");
        console.log("RUNBOOK (executed by the staking gov, then verified by 04_AssertBwlkDeploy):");
        console.log("1. RewardTracker.setHandler(migrator, true) on stakedBWLK/bonusBWLK/feeBWLK:");
        console.log("   migrator =", migrator);
        console.log("   staked   =", stakedBwlkTracker);
        console.log("   bonus    =", bonusBwlkTracker);
        console.log("   fee      =", feeBwlkTracker);
        console.log("2. MintableBaseToken(bnBWLK).setMinter(migrator, true):", bnBwlk);
        console.log("3. Trackers handler-wired to each other; deposit tokens set (BWLK->staked,");
        console.log("   staked->bonus, bonus+bnBWLK->fee); each tracker initialize()d with a");
        console.log("   RewardDistributor whose rewardTracker points back at it (gate D-3).");
        console.log("4. Transfer gov of all three trackers + bnBWLK to the staking multisig/timelock");
        console.log("   (setGov) - the gate asserts gov() == STAKING_GOV (F-1).");
        console.log("5. AFTER migration + sweep: REVOKE the migrator's bnBWLK minter role");
        console.log("   (setMinter(migrator,false)) - the hard cap on point inflation (F-1).");
    }
}

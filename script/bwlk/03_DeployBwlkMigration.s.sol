// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BwlkMigration} from "src/token/BwlkMigration.sol";
import {EthereumConfig} from "./EthereumConfig.sol";

/// @title DeployBwlkMigration - Deploy + bring up the BMX -> BWLK Migrator on Ethereum mainnet
/// @notice Deploys BwlkMigration and, when the broadcaster is the owner (bring-up), sets the
///         one-shot snapshot merkle root in the same broadcast. The 2,711,068 BWLK pool is NEVER
///         funded by this script: fund it manually (escrow -> migrator) only after verifying the
///         root on-chain. When OWNER is not the broadcaster it deploys only and prints the
///         root-first bring-up steps.
/// @dev Sequencing matters: the root must be set (and verified) BEFORE the pool is funded. A mis-set
///      root on an empty migrator is a cheap redeploy; a funded migrator locks the pool — 86% of the
///      fixed supply — until CLAIM_DEADLINE (sweepUnclaimed is deadline-gated), and no replacement
///      migrator could be funded meanwhile. The root is one-shot on-chain; corrections after go-live
///      flow only through `creditPoints`. Keeping the funding transfer out of this script means the
///      pool leaves the escrow only after the root is a verified on-chain fact.
///
///      Required env: DEPLOYER_PRIVATE_KEY, BWLK_TOKEN, STAKED_BWLK_TRACKER, BONUS_BWLK_TRACKER,
///      FEE_BWLK_TRACKER, BN_BWLK, GOVERNANCE_VOTER, MERKLE_ROOT, OWNER (the bring-up owner, or
///      the governance timelock for a deploy-only run). BMX_ADDRESS is required (no default: the
///      Ethereum-side migration source is being re-scoped). Optional env: CLAIM_DEADLINE (default
///      EthereumConfig.MIGRATION_CLAIM_DEADLINE = Jan 20 2027, 11:00 PST).
contract DeployBwlkMigration is Script {
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
        uint256 claimDeadline = vm.envOr("CLAIM_DEADLINE", EthereumConfig.MIGRATION_CLAIM_DEADLINE);

        vm.startBroadcast(deployerPrivateKey);

        BwlkMigration migrator = new BwlkMigration(
            owner, bmx, bwlk, stakedBwlkTracker, bonusBwlkTracker, feeBwlkTracker, bnBwlk, voter, claimDeadline
        );
        console.log("BwlkMigration deployed to:", address(migrator));
        console.log("  owner:", owner);
        console.log("  claimDeadline:", claimDeadline);

        // Root BEFORE funding, always. A mis-set root on an empty migrator is a cheap redeploy, but a
        // funded migrator locks the pool until CLAIM_DEADLINE (sweepUnclaimed is deadline-gated).
        // Funding itself is deliberately NOT done here: the escrow sends the pool to the migrator
        // manually, only after the root below is verified on-chain.
        if (owner == deployer) {
            migrator.setMerkleRoot(merkleRoot);
            console.log("setMerkleRoot done (broadcaster is owner). Next, in order:");
            console.log("1. Verify migrator.merkleRoot() matches the artifact root.");
            console.log("2. Only then fund the pool (escrow -> migrator):", EthereumConfig.MIGRATION_POOL);
        } else {
            console.log("OWNER is not the broadcaster: root not set. In order:");
            console.log("1. Owner calls migrator.setMerkleRoot with the verified artifact root:");
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
        console.log("3. bnBWLK.setHandler(BonusDistributor, true) AND bnBWLK.setHandler(bonusBWLK");
        console.log("   tracker, true): bnBWLK runs inPrivateTransferMode, and distribute() /");
        console.log("   claimForAccount SEND bnBWLK as those contracts - without both grants every");
        console.log("   bonus-tier interaction (including migrate) reverts once bn rewards are");
        console.log("   pending. Then fund the BonusDistributor with bnBWLK (gov self-mint).");
        console.log("4. Trackers handler-wired to each other; deposit tokens set (BWLK->staked,");
        console.log("   staked->bonus, bonus+bnBWLK->fee); each tracker initialize()d with a");
        console.log("   RewardDistributor whose rewardTracker points back at it (gate D-3).");
        console.log("5. Transfer gov of all three trackers + bnBWLK to the staking multisig/timelock");
        console.log("   (setGov) - the gate asserts gov() == STAKING_GOV (F-1).");
        console.log("6. AFTER migration + sweep: REVOKE the migrator's bnBWLK minter role");
        console.log("   (setMinter(migrator,false)) - the hard cap on point inflation (F-1).");
    }
}

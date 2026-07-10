import { getAddress, type Address } from "viem";
import { clientFor, ERC20_ABI, REWARD_TRACKER_ABI } from "./clients.js";
import {
  BASE_STAKING,
  BMX_ADDRESS,
  CHAIN_KEYS,
  DEAD_ADDRESS,
  KNOWN_EXCLUDED,
  LOCKED_BMX_HOLDERS,
  MIGRATION_POOL_BWS,
  snapshotBlock,
  ZERO_ADDRESS,
  type ChainKey,
} from "./config.js";
import { outPath, readJson } from "./io.js";

/** Minimal ABI for the staked tracker's total deposit supply (on-chain total of all staked BMX). */
const TOTAL_DEPOSIT_SUPPLY_ABI = [
  {
    type: "function",
    name: "totalDepositSupply",
    stateMutability: "view",
    inputs: [{ name: "depositToken", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

interface AggEntry {
  account: Address;
  perChain: Record<ChainKey, string>;
  baseStakedBmx: string;
  snapshotBmx: string;
  snapshotPoints: string;
}

const SAMPLE_SIZE = 20;

/**
 * Pre-publish validation gate (stakers-only snapshot). Exits non-zero on any failure. Three checks:
 *
 *  (a) Re-read a random sample of staker leaves: snapshotBmx must equal live Base staked BMX and
 *      snapshotPoints the live multiplier points (the informational per-chain wallet columns too).
 *  (b) Completeness: the aggregate of all snapshotBmx must equal the staked tracker's on-chain
 *      totalDepositSupply(BMX), and the aggregate of all snapshotPoints must equal sbfBMX's
 *      totalDepositSupply(bnBMX) - i.e. the snapshot captured every staker's stake AND points
 *      (a shortfall = missed staker or a zeroed read).
 *  (c) Pool coverage (feeds on-chain D-1): every holder migrates 1:1, so the pool must cover ALL
 *      migratable BMX = sum of per-chain totalSupply minus the dead/zero-held BMX and the enumerated
 *      LOCKED_BMX_HOLDERS (e.g. Base oBMX - protocol BMX that can never reach migrate()). Staked BMX
 *      stays in - stakers unstake and migrate it.
 */
async function main(): Promise<void> {
  const { entries } = readJson<{ entries: AggEntry[] }>(outPath("aggregate.json"));
  if (entries.length === 0) {
    fail("aggregate.json has no entries — run the snapshot first.");
  }

  // The root is one-shot and unrecoverable: refuse to validate against an unpinned (drifting) state.
  // Every chain must have a pinned SNAPSHOT_BLOCK_* so the re-read (a) and reconciliation (b) read
  // exactly the state the tree was built from.
  const unpinned = CHAIN_KEYS.filter((c) => snapshotBlock(c) === "latest");
  if (unpinned.length > 0) {
    fail(`refusing to validate against an unpinned snapshot. Set SNAPSHOT_BLOCK_* for: ${unpinned.join(", ")}.`);
  }

  let failures = 0;

  // ---- (a) sample re-read -----------------------------------------------------------------
  console.log(`\n[validate] (a) re-reading a random sample of ${SAMPLE_SIZE} staker leaves...`);
  const sample = pickSample(entries, SAMPLE_SIZE);
  const baseClient = clientFor("base");
  const baseBlock = blockOrLatest("base", await baseClient.getBlockNumber());

  for (const e of sample) {
    const account = getAddress(e.account);

    // Informational per-chain wallet columns (not part of the leaf): confirm the CSV matches live.
    for (const chain of CHAIN_KEYS) {
      const client = clientFor(chain);
      const block = blockOrLatest(chain, await client.getBlockNumber());
      const bal = (await client.readContract({
        address: BMX_ADDRESS[chain],
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: [account],
        blockNumber: block,
      })) as bigint;
      if (bal !== BigInt(e.perChain[chain])) {
        console.error(`  MISMATCH ${account} ${chain} wallet: live ${bal} != aggregate ${e.perChain[chain]}`);
        failures++;
      }
    }

    // The leaf: snapshotBmx = Base staked BMX, snapshotPoints = Base multiplier points.
    const stakedBmx = (await baseClient.readContract({
      address: BASE_STAKING.stakedBmxTracker,
      abi: REWARD_TRACKER_ABI,
      functionName: "depositBalances",
      args: [account, BMX_ADDRESS.base],
      blockNumber: baseBlock,
    })) as bigint;
    const points = (await baseClient.readContract({
      address: BASE_STAKING.feeBmxTracker,
      abi: REWARD_TRACKER_ABI,
      functionName: "depositBalances",
      args: [account, BASE_STAKING.bnBMX],
      blockNumber: baseBlock,
    })) as bigint;

    if (stakedBmx !== BigInt(e.snapshotBmx)) {
      console.error(`  MISMATCH ${account} snapshotBmx (staked): live ${stakedBmx} != aggregate ${e.snapshotBmx}`);
      failures++;
    }
    if (points !== BigInt(e.snapshotPoints)) {
      console.error(`  MISMATCH ${account} snapshotPoints: live ${points} != aggregate ${e.snapshotPoints}`);
      failures++;
    }
  }
  if (failures === 0) console.log(`  sample OK (${sample.length} staker leaves match live reads)`);

  // ---- (b) snapshot completeness ----------------------------------------------------------
  console.log(`\n[validate] (b) verifying the snapshot captured all staked BMX...`);

  // Precondition for the exact-match sums below: no KNOWN_EXCLUDED address may hold a staked
  // position (an excluded staker gets no leaf, so the sums would fail with a misleading
  // "discovery missed a staker" message). Assert it explicitly.
  for (const excluded of KNOWN_EXCLUDED) {
    const [exStaked, exPoints] = await Promise.all([
      baseClient.readContract({
        address: BASE_STAKING.stakedBmxTracker,
        abi: REWARD_TRACKER_ABI,
        functionName: "depositBalances",
        args: [excluded, BMX_ADDRESS.base],
        blockNumber: baseBlock,
      }) as Promise<bigint>,
      baseClient.readContract({
        address: BASE_STAKING.feeBmxTracker,
        abi: REWARD_TRACKER_ABI,
        functionName: "depositBalances",
        args: [excluded, BASE_STAKING.bnBMX],
        blockNumber: baseBlock,
      }) as Promise<bigint>,
    ]);
    if (exStaked !== 0n || exPoints !== 0n) {
      console.error(
        `  FAIL: KNOWN_EXCLUDED address ${excluded} has a staked position (staked ${exStaked}, points ${exPoints}) - ` +
          `it gets no leaf, so the (b) sums below cannot match. Remove it from the exclusion list or resolve its stake.`,
      );
      failures++;
    }
  }
  const aggTotalStaked = entries.reduce((acc, e) => acc + BigInt(e.snapshotBmx), 0n);
  const totalStakedOnChain = (await baseClient.readContract({
    address: BASE_STAKING.stakedBmxTracker,
    abi: TOTAL_DEPOSIT_SUPPLY_ABI,
    functionName: "totalDepositSupply",
    args: [BMX_ADDRESS.base],
    blockNumber: baseBlock,
  })) as bigint;
  console.log(`  aggregate staked snapshotBmx: ${aggTotalStaked}`);
  console.log(`  stakedBmxTracker.totalDepositSupply(BMX): ${totalStakedOnChain}`);
  if (aggTotalStaked !== totalStakedOnChain) {
    console.error(
      `  FAIL: captured staked (${aggTotalStaked}) != on-chain total staked (${totalStakedOnChain}) - discovery missed a staker.`,
    );
    failures++;
  } else {
    console.log(`  OK: snapshot captures every staker's staked BMX`);
  }

  // Points side of the same reconciliation: catches a zeroed/missed points read even when the
  // staked sum matches.
  const aggTotalPoints = entries.reduce((acc, e) => acc + BigInt(e.snapshotPoints), 0n);
  const totalPointsOnChain = (await baseClient.readContract({
    address: BASE_STAKING.feeBmxTracker,
    abi: TOTAL_DEPOSIT_SUPPLY_ABI,
    functionName: "totalDepositSupply",
    args: [BASE_STAKING.bnBMX],
    blockNumber: baseBlock,
  })) as bigint;
  console.log(`  aggregate snapshotPoints: ${aggTotalPoints}`);
  console.log(`  feeBmxTracker.totalDepositSupply(bnBMX): ${totalPointsOnChain}`);
  if (aggTotalPoints !== totalPointsOnChain) {
    console.error(
      `  FAIL: captured points (${aggTotalPoints}) != on-chain total points (${totalPointsOnChain}) - missed or zeroed points read.`,
    );
    failures++;
  } else {
    console.log(`  OK: snapshot captures every staker's points`);
  }

  // ---- (c) migration pool coverage (feeds on-chain D-1) -----------------------------------
  console.log(`\n[validate] (c) migration pool coverage (every holder migrates 1:1)...`);
  let migratable = 0n;
  for (const chain of CHAIN_KEYS) {
    const client = clientFor(chain);
    const block = blockOrLatest(chain, await client.getBlockNumber());
    const supply = (await client.readContract({
      address: BMX_ADDRESS[chain],
      abi: ERC20_ABI,
      functionName: "totalSupply",
      blockNumber: block,
    })) as bigint;
    const dead = await nonMigratableBmx(chain, block);
    migratable += supply - dead;
    console.log(`  ${chain}: totalSupply ${supply} - dead/zero/locked ${dead}`);
  }
  console.log(`  migration pool: ${MIGRATION_POOL_BWS}`);
  console.log(`  total migratable BMX (all chains, staked included): ${migratable}`);
  if (MIGRATION_POOL_BWS < migratable) {
    console.error(`  FAIL: migration pool (${MIGRATION_POOL_BWS}) < total migratable BMX (${migratable}).`);
    failures++;
  } else {
    console.log(`  OK: pool >= total migratable`);
  }

  if (failures > 0) {
    console.error(`\n[validate] FAILED with ${failures} issue(s).`);
    process.exit(1);
  }
  console.log(`\n[validate] all checks passed.`);
}

/** BMX that can never reach `migrate()` on `chain`: held by dead/zero plus the enumerated
 *  LOCKED_BMX_HOLDERS (e.g. Base oBMX, whose ~272k protocol BMX is permanently inaccessible). Staked
 *  BMX (held by the tracker) is NOT subtracted: stakers unstake and migrate it, so it must be covered
 *  by the pool. Other contract-held BMX (LP pairs etc.) is left in as a conservative D-1 upper bound. */
async function nonMigratableBmx(chain: ChainKey, block: bigint): Promise<bigint> {
  const client = clientFor(chain);
  let sum = 0n;
  for (const addr of [DEAD_ADDRESS, ZERO_ADDRESS, ...(LOCKED_BMX_HOLDERS[chain] ?? [])]) {
    // No try/catch: a failed read must abort the run, not silently skew the deduction.
    sum += (await client.readContract({
      address: BMX_ADDRESS[chain],
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [addr],
      blockNumber: block,
    })) as bigint;
  }
  return sum;
}

function pickSample(entries: AggEntry[], n: number): AggEntry[] {
  if (entries.length <= n) return entries;
  const idx = new Set<number>();
  while (idx.size < n) idx.add(Math.floor(Math.random() * entries.length));
  return [...idx].map((i) => entries[i]!);
}

function blockOrLatest(chain: ChainKey, latest: bigint): bigint {
  const target = snapshotBlock(chain);
  return target === "latest" ? latest : target;
}

function fail(msg: string): never {
  console.error(`[validate] ${msg}`);
  process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

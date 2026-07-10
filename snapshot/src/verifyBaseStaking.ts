import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import {
  createPublicClient,
  getAddress,
  http,
  parseAbiItem,
  type Address,
} from "viem";
import { base } from "viem/chains";
import { BASE_STAKING, BMX_ADDRESS, ZERO_ADDRESS } from "./config.js";
import { isExcluded } from "./exclusions.js";
import { fileExists, outPath, readJson, writeJson, writeText } from "./io.js";
import { LEAF_ENCODING, type LeafValue } from "./leaves.js";

/**
 * Independent verification of the STAKERS-ONLY Base snapshot against live on-chain state.
 *
 *   1. Enumerate every staker by scanning the staked tracker's mint logs (Transfer from 0x0). This is
 *      a DIFFERENT discovery path than the production pipeline (which scans BMX transfers), so a match
 *      cross-validates both.
 *   2. Read each candidate's depositBalances at one pinned block: staked BMX (snapshotBmx) on the
 *      staked tracker, and multiplier points (snapshotPoints) on sbfBMX.
 *   3. Keep stakers (staked > 0 || points > 0) minus the same protocol allowlist the pipeline
 *      excludes (exclusions.ts), and build the same StandardMerkleTree the pipeline builds.
 *   4. Assert the aggregate sums equal the trackers' on-chain totals - the ground-truth correctness +
 *      completeness proof:
 *        sum(snapshotBmx)    == stakedTracker.totalDepositSupply(BMX)
 *        sum(snapshotPoints) == sbfBMX.totalDepositSupply(bnBMX)
 *   5. Re-read a random sample of leaves with single eth_calls (no multicall) as a second source.
 *
 * Run: RPC_BASE=<archive-or-fast-rpc> npx tsx src/verifyBaseStaking.ts
 */

const STAKED_TRACKER_DEPLOY_BLOCK = 8_744_768n; // Base, Jan 2024 (binary-searched)

const TRANSFER = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 value)");

const DEPOSIT_BALANCES_ABI = [
  {
    type: "function",
    name: "depositBalances",
    stateMutability: "view",
    inputs: [
      { name: "account", type: "address" },
      { name: "depositToken", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

const TOTALS_ABI = [
  {
    type: "function",
    name: "totalDepositSupply",
    stateMutability: "view",
    inputs: [{ name: "depositToken", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

// Public Base RPCs all cap eth_getLogs at a 10k block range, so the scan is chunked + spread across a
// pool with bounded concurrency and retry. State reads (totals/multicall/sample) use the primary.
const PRIMARY_RPC = process.env.RPC_BASE ?? "https://mainnet.base.org";
const RPC_POOL = [
  PRIMARY_RPC,
  "https://base.publicnode.com",
  "https://base.drpc.org",
  "https://base-mainnet.public.blastapi.io",
  "https://base.meowrpc.com",
  "https://rpc.ankr.com/base",
];
const client = createPublicClient({ chain: base, transport: http(PRIMARY_RPC) });
const scanClients = RPC_POOL.map((url) => createPublicClient({ chain: base, transport: http(url) }));

const CHUNK = 9_000n; // under the universal 10k getLogs cap

function fmt(wei: bigint): string {
  return (Number(wei) / 1e18).toLocaleString("en-US", { maximumFractionDigits: 2 });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** getLogs for one range, rotating across the RPC pool with backoff. Returns null if all attempts fail
 *  (the caller re-queues it rather than aborting, so a transient rate-limit never drops a range). */
async function getMintsForRange(
  start: bigint,
  end: bigint,
  rotate: number,
  attempts: number,
): Promise<`0x${string}`[] | null> {
  for (let attempt = 0; attempt < attempts; attempt++) {
    const c = scanClients[(rotate + attempt) % scanClients.length]!;
    try {
      const logs = await c.getLogs({
        address: BASE_STAKING.stakedBmxTracker,
        event: TRANSFER,
        args: { from: ZERO_ADDRESS },
        fromBlock: start,
        toBlock: end,
      });
      return logs.map((l) => l.args.to!).filter(Boolean) as `0x${string}`[];
    } catch {
      await sleep(200 * (attempt + 1)); // backoff, then try the next RPC
    }
  }
  return null;
}

/** Cached, bounded-concurrency scan of staker addresses from the staked tracker's mint events.
 *  Failed ranges are re-queued and drained sequentially; only a truly unrecoverable range aborts. */
async function discoverStakers(toBlock: bigint): Promise<Address[]> {
  const cachePath = outPath("base-stakers.json");
  const seen = new Set<string>();
  let scanFrom = STAKED_TRACKER_DEPLOY_BLOCK;
  if (fileExists(cachePath)) {
    const cached = readJson<{ toBlock: string; stakers: string[] }>(cachePath);
    for (const a of cached.stakers) seen.add(a.toLowerCase());
    const cachedTo = BigInt(cached.toBlock);
    if (cachedTo >= toBlock) {
      console.log(`[verify] cache covers block ${toBlock} (${seen.size} stakers)`);
      return [...seen].map((a) => getAddress(a));
    }
    scanFrom = cachedTo + 1n;
    console.log(`[verify] cache has ${seen.size} stakers to block ${cachedTo}; scanning delta -> ${toBlock}`);
  }

  let queue: Array<[bigint, bigint]> = [];
  for (let s = scanFrom; s <= toBlock; s += CHUNK) {
    queue.push([s, s + CHUNK - 1n > toBlock ? toBlock : s + CHUNK - 1n]);
  }
  const total = queue.length;
  console.log(`[verify] scanning ${total} chunks of ${CHUNK} blocks across ${RPC_POOL.length} RPCs...`);

  let done = 0;

  // Phase 1: gentle concurrency (keeps each RPC well under its rate limit). Phase 2+: drain stragglers
  // with concurrency 1 and more attempts. Up to 6 passes; abort only if a range still won't load.
  for (let pass = 0; pass < 6 && queue.length > 0; pass++) {
    const concurrency = pass === 0 ? 4 : 1;
    const attempts = pass === 0 ? 6 : 12;
    const failed: Array<[bigint, bigint]> = [];
    let next = 0;
    const ranges = queue;
    async function worker(idx: number): Promise<void> {
      while (true) {
        const i = next++;
        if (i >= ranges.length) return;
        const [a, b] = ranges[i]!;
        const tos = await getMintsForRange(a, b, idx + pass, attempts);
        if (tos === null) {
          failed.push([a, b]);
        } else {
          for (const to of tos) if (to !== ZERO_ADDRESS) seen.add(getAddress(to).toLowerCase());
        }
        if (++done % 200 === 0) console.log(`[verify]   ${done}/${total} chunks (${seen.size} stakers so far)`);
      }
    }
    await Promise.all(Array.from({ length: concurrency }, (_, k) => worker(k)));
    queue = failed;
    if (queue.length > 0) console.log(`[verify]   pass ${pass} left ${queue.length} ranges to retry...`);
  }
  if (queue.length > 0) {
    throw new Error(`could not scan ${queue.length} ranges after retries (first: ${queue[0]}). Try a private RPC_BASE.`);
  }

  const stakers = [...seen].map((a) => getAddress(a));
  writeJson(cachePath, { toBlock: toBlock.toString(), stakers });
  console.log(`[verify] discovered ${stakers.length} unique stakers (mint events) -> ${cachePath}`);
  return stakers;
}

/** Concurrently read each staker's staked BMX + points at a pinned block via individual eth_calls,
 *  rotated across the RPC pool with retry. (Public RPCs reject the large multicall3 batch.) */
async function readStakerBalances(
  accounts: Address[],
  bmx: Address,
  blockNumber: bigint,
): Promise<Map<string, { staked: bigint; points: bigint }>> {
  const out = new Map<string, { staked: bigint; points: bigint }>();
  let next = 0;
  let done = 0;
  const CONC = 8;

  async function worker(w: number): Promise<void> {
    while (true) {
      const i = next++;
      if (i >= accounts.length) return;
      const a = accounts[i]!;
      let rec: { staked: bigint; points: bigint } | undefined;
      for (let att = 0; att < 10 && !rec; att++) {
        const c = scanClients[(w + att) % scanClients.length]!;
        try {
          const [staked, points] = await Promise.all([
            c.readContract({
              address: BASE_STAKING.stakedBmxTracker,
              abi: DEPOSIT_BALANCES_ABI,
              functionName: "depositBalances",
              args: [a, bmx],
              blockNumber,
            }) as Promise<bigint>,
            c.readContract({
              address: BASE_STAKING.feeBmxTracker,
              abi: DEPOSIT_BALANCES_ABI,
              functionName: "depositBalances",
              args: [a, BASE_STAKING.bnBMX],
              blockNumber,
            }) as Promise<bigint>,
          ]);
          rec = { staked, points };
        } catch {
          await sleep(150 * (att + 1));
        }
      }
      if (!rec) throw new Error(`balance read failed for ${a}`);
      out.set(a.toLowerCase(), rec);
      if (++done % 200 === 0) console.log(`[verify]   read ${done}/${accounts.length} balances`);
    }
  }
  await Promise.all(Array.from({ length: CONC }, (_, k) => worker(k)));
  return out;
}

async function main(): Promise<void> {
  const latest = await client.getBlockNumber();
  // Pin a very recent block so non-archive RPCs still serve state for the per-staker reads.
  const block = process.env.SNAPSHOT_BLOCK_BASE ? BigInt(process.env.SNAPSHOT_BLOCK_BASE) : latest - 3n;
  console.log(`[verify] primary RPC ${PRIMARY_RPC}`);
  console.log(`[verify] pinned block ${block} (latest ${latest})`);

  const bmx = BMX_ADDRESS.base;

  // Ground-truth on-chain totals at the pinned block.
  const [totalStaked, totalPoints] = await Promise.all([
    client.readContract({
      address: BASE_STAKING.stakedBmxTracker,
      abi: TOTALS_ABI,
      functionName: "totalDepositSupply",
      args: [bmx],
      blockNumber: block,
    }) as Promise<bigint>,
    client.readContract({
      address: BASE_STAKING.feeBmxTracker,
      abi: TOTALS_ABI,
      functionName: "totalDepositSupply",
      args: [BASE_STAKING.bnBMX],
      blockNumber: block,
    }) as Promise<bigint>,
  ]);
  console.log(`[verify] on-chain totalDepositSupply(BMX)   = ${totalStaked} (${fmt(totalStaked)} BMX)`);
  console.log(`[verify] on-chain totalDepositSupply(bnBMX) = ${totalPoints} (${fmt(totalPoints)} pts)`);

  // 1. enumerate stakers, 2. read balances at the pinned block.
  const candidates = await discoverStakers(block);
  console.log(`[verify] reading depositBalances for ${candidates.length} candidates at block ${block}...`);
  const balances = await readStakerBalances(candidates, bmx, block);

  // 3. build entries (stakers only) + the tree.
  const values: LeafValue[] = [];
  let sumStaked = 0n;
  let sumPoints = 0n;
  const csv: string[] = ["address,snapshotBmx,snapshotPoints"];
  for (const a of candidates) {
    const lower = a.toLowerCase();
    if (isExcluded(a)) continue;
    const rec = balances.get(lower) ?? { staked: 0n, points: 0n };
    const staked = rec.staked;
    const pts = rec.points;
    if (staked === 0n && pts === 0n) continue;
    values.push([a, staked.toString(), pts.toString()]);
    sumStaked += staked;
    sumPoints += pts;
    csv.push(`${a},${staked},${pts}`);
  }
  values.sort((x, y) => (x[0].toLowerCase() < y[0].toLowerCase() ? -1 : 1));
  const tree = StandardMerkleTree.of(values, [...LEAF_ENCODING]);

  // 4. the correctness + completeness proof.
  const stakedOk = sumStaked === totalStaked;
  const pointsOk = sumPoints === totalPoints;
  console.log("");
  console.log(`[verify] stakers with a leaf: ${values.length}`);
  console.log(`[verify] sum(snapshotBmx)    = ${sumStaked} (${fmt(sumStaked)})  vs on-chain ${fmt(totalStaked)}  -> ${stakedOk ? "MATCH" : "MISMATCH"}`);
  console.log(`[verify] sum(snapshotPoints) = ${sumPoints} (${fmt(sumPoints)})  vs on-chain ${fmt(totalPoints)}  -> ${pointsOk ? "MATCH" : "MISMATCH"}`);
  console.log(`[verify] merkle root = ${tree.root}`);

  // Write the artifact first so it always lands, regardless of the (secondary) sample re-read.
  writeText(outPath("base-staking-snapshot.csv"), csv.join("\n") + "\n");
  writeJson(outPath("base-staking-verification.json"), {
    block: block.toString(),
    rpc: PRIMARY_RPC,
    stakerCount: values.length,
    sumSnapshotBmx: sumStaked.toString(),
    onChainTotalStaked: totalStaked.toString(),
    sumSnapshotPoints: sumPoints.toString(),
    onChainTotalPoints: totalPoints.toString(),
    root: tree.root,
    stakedMatch: stakedOk,
    pointsMatch: pointsOk,
  });
  console.log(`[verify] wrote out/base-staking-snapshot.csv + out/base-staking-verification.json`);

  // 5. Independent single-call re-read of a random sample (rotated across the pool, retried,
  //    non-fatal: a flaky RPC here does not invalidate the sum-match proof above).
  const sampleN = Math.min(15, values.length);
  let sampleOk = 0;
  let sampleErr = 0;
  for (let k = 0; k < sampleN; k++) {
    const idx = (k * 7919) % values.length; // deterministic spread
    const [acct, sBmx, sPts] = values[idx]!;
    let live: [bigint, bigint] | undefined;
    for (let att = 0; att < 8 && !live; att++) {
      const c = scanClients[(k + att) % scanClients.length]!;
      try {
        live = (await Promise.all([
          c.readContract({ address: BASE_STAKING.stakedBmxTracker, abi: DEPOSIT_BALANCES_ABI, functionName: "depositBalances", args: [acct as Address, bmx], blockNumber: block }),
          c.readContract({ address: BASE_STAKING.feeBmxTracker, abi: DEPOSIT_BALANCES_ABI, functionName: "depositBalances", args: [acct as Address, BASE_STAKING.bnBMX], blockNumber: block }),
        ])) as [bigint, bigint];
      } catch {
        await sleep(150 * (att + 1));
      }
    }
    if (!live) {
      sampleErr++;
      continue;
    }
    if (live[0].toString() === sBmx && live[1].toString() === sPts) sampleOk++;
    else console.error(`  SAMPLE MISMATCH ${acct}: tree (${sBmx},${sPts}) != live (${live[0]},${live[1]})`);
  }
  console.log(`[verify] sample re-read: ${sampleOk}/${sampleN - sampleErr} checked leaves match live single-call reads (${sampleErr} skipped on RPC error)`);

  const pass = stakedOk && pointsOk && sampleOk === sampleN - sampleErr;
  console.log("");
  console.log(pass ? "[verify] PASS - snapshot reconciles exactly with on-chain staked state." : "[verify] FAIL - see mismatches above.");
  if (!pass) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

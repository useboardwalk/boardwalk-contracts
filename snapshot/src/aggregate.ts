import { getAddress, type Address } from "viem";
import { CHAIN_KEYS, type ChainKey } from "./config.js";
import { discoverHolders } from "./discoverHolders.js";
import { isExcluded } from "./exclusions.js";
import { outPath, writeJson, writeText } from "./io.js";
import { readBalances, type BalanceMap } from "./readBalances.js";
import { readStakedPoints, type StakedMap } from "./readStakedPoints.js";

export interface AggregatedEntry {
  account: Address;
  perChain: Record<ChainKey, string>;
  baseStakedBmx: string;
  /** Staked (compounded) points: sbfBMX.depositBalances(user, bnBMX) (wei, decimal string). */
  baseStakedPoints: string;
  /** Pending points: bonusBmxTracker.claimable(user) (wei, decimal string). */
  basePendingPoints: string;
  /** snapshotBmx = baseStakedBmx (the carry-ratio denominator; wei, decimal string). Only stakers
   *  get an entry - non-stakers earn the 16% base credit on-chain without a leaf. */
  snapshotBmx: string;
  /** snapshotPoints = baseStakedPoints + basePendingPoints (wei, decimal string). */
  snapshotPoints: string;
}

const ZERO_PER_CHAIN: Record<ChainKey, string> = {
  ethereum: "0",
  base: "0",
  fraxtal: "0",
  katana: "0",
  ink: "0",
  arbitrum: "0",
};

/**
 * Run the full aggregation: discover candidates, read Base staking (+ per-chain wallet BMX for the
 * informational CSV), drop protocol addresses (allowlist), dedup, and produce the per-account leaves.
 *
 * The snapshot is STAKERS ONLY: snapshotBmx = Base staked BMX (depositBalances(user, BMX)),
 * snapshotPoints = staked points (sbfBMX.depositBalances(user, bnBMX)) + pending points
 * (bonusBmxTracker.claimable(user)). Non-stakers are excluded entirely - the
 * migration contract grants every migrator the 16% base credit on their migrated BMX without a leaf.
 * Contract-account stakers (Safes, 7702-delegated EOAs) keep their leaves: migrate has no EOA gate,
 * and dropping them would forfeit their points and break the validate (b) sum reconciliation.
 *
 * Writes out/aggregate.json and out/snapshot.csv. Returns the entries (sorted by address).
 */
export async function aggregate(): Promise<AggregatedEntry[]> {
  // 1. Per-chain wallet balances.
  const perChainBalances = new Map<ChainKey, BalanceMap>();
  for (const chain of CHAIN_KEYS) {
    const candidates = await discoverHolders(chain);
    const balances = await readBalances(chain, candidates);
    perChainBalances.set(chain, balances);
  }

  // 2. Union of all addresses seen with a non-zero wallet balance, plus Base staking participants.
  //    Base staking users may hold zero wallet BMX yet still have staked BMX/points, so seed the
  //    union from Base candidates too.
  const baseCandidates = await discoverHolders("base");
  const union = new Set<string>();
  for (const balances of perChainBalances.values()) {
    for (const k of balances.keys()) union.add(k);
  }
  for (const a of baseCandidates) union.add(a.toLowerCase());

  // 3. Base staking reads for the full union (checksummed).
  const unionAddrs: Address[] = [...union].map((a) => getAddress(a));
  const staked: StakedMap = await readStakedPoints(unionAddrs);

  // 4. Build entries. Exclusion is allowlist-only (zero/dead/known protocol contracts): contract
  //    accounts that stake are real migrators and must keep their leaves (see exclusions.ts).
  const entries: AggregatedEntry[] = [];
  for (const addr of unionAddrs) {
    const lower = addr.toLowerCase();
    if (isExcluded(addr)) continue;

    const perChain: Record<ChainKey, string> = { ...ZERO_PER_CHAIN };
    for (const chain of CHAIN_KEYS) {
      perChain[chain] = (perChainBalances.get(chain)!.get(lower) ?? 0n).toString();
    }

    const stakeRead = staked.get(lower);
    const baseStakedBmx = stakeRead?.stakedBmx ?? 0n;
    const stakedPoints = stakeRead?.stakedPoints ?? 0n;
    const pendingPoints = stakeRead?.pendingPoints ?? 0n;

    // snapshotBmx = the staker's Base staked BMX (the carry-ratio denominator). Per-chain wallet BMX
    // is informational only (CSV): every migrator earns the 16% base credit on-chain on whatever they
    // migrate, so non-stakers need no leaf - they are dropped by the filter below.
    const snapshotBmx = baseStakedBmx;
    if (snapshotBmx === 0n && stakedPoints === 0n && pendingPoints === 0n) continue;

    entries.push({
      account: addr,
      perChain,
      baseStakedBmx: baseStakedBmx.toString(),
      baseStakedPoints: stakedPoints.toString(),
      basePendingPoints: pendingPoints.toString(),
      snapshotBmx: snapshotBmx.toString(),
      snapshotPoints: (stakedPoints + pendingPoints).toString(),
    });
  }

  entries.sort((a, b) => (a.account.toLowerCase() < b.account.toLowerCase() ? -1 : 1));

  writeJson(outPath("aggregate.json"), { count: entries.length, entries });
  writeCsv(entries);
  console.log(`[aggregate] ${entries.length} staker leaves -> out/aggregate.json, out/snapshot.csv`);
  return entries;
}

function writeCsv(entries: AggregatedEntry[]): void {
  const header =
    "address,eth_bmx,base_bmx,fraxtal_bmx,katana_bmx,ink_bmx,arbitrum_bmx,base_staked_bmx,base_staked_points,base_pending_points,snapshotBmx,snapshotPoints";
  const rows = entries.map((e) =>
    [
      e.account,
      e.perChain.ethereum,
      e.perChain.base,
      e.perChain.fraxtal,
      e.perChain.katana,
      e.perChain.ink,
      e.perChain.arbitrum,
      e.baseStakedBmx,
      e.baseStakedPoints,
      e.basePendingPoints,
      e.snapshotBmx,
      e.snapshotPoints,
    ].join(","),
  );
  writeText(outPath("snapshot.csv"), [header, ...rows].join("\n") + "\n");
}

if (import.meta.url === `file://${process.argv[1]}`) {
  aggregate().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}

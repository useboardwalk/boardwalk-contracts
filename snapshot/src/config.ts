import "dotenv/config";
import { getAddress, type Address } from "viem";

/**
 * Central configuration for the BMX->BWS snapshot pipeline.
 *
 * Every address here is checksummed via viem `getAddress` at module load, which doubles as a
 * byte-level sanity check: a typo in a hex char throws on import. Cross-check these against the
 * deployment records / block explorers before any production run.
 */

export type ChainKey =
  | "ethereum"
  | "base"
  | "fraxtal"
  | "katana"
  | "ink"
  | "arbitrum";

export const CHAIN_KEYS: ChainKey[] = [
  "ethereum",
  "base",
  "fraxtal",
  "katana",
  "ink",
  "arbitrum",
];

/** numeric chain ids, for reference / logging. */
export const CHAIN_IDS: Record<ChainKey, number> = {
  ethereum: 1,
  base: 8453,
  fraxtal: 252,
  katana: 747474,
  ink: 57073,
  arbitrum: 42161,
};

/** BMX token address on each chain. */
export const BMX_ADDRESS: Record<ChainKey, Address> = {
  ethereum: getAddress("0xd55159fe5633e24510d5317d224324413407c5b8"),
  base: getAddress("0x548f93779fbc992010c07467cbaf329dd5f059b7"),
  fraxtal: getAddress("0xea34ebbc94df7bfec5d9cdcd373a4221b7c87810"),
  katana: getAddress("0xbdcaaa7439a0fc6e01326d36ab8d72cceecd1f5a"),
  ink: getAddress("0x5e8a26a9ed06b56bc1d90ceee2c6ae892b4b835c"),
  arbitrum: getAddress("0xc2694a5c9f3a886d0467fce5e07f6211dfc86c48"),
};

/**
 * Base staking contracts (GMX-style 3-tier trackers). Staked BMX and multiplier points live here.
 *  - stakedBmxTracker: deposit token BMX. `depositBalances(user, BMX)` = staked BMX component.
 *  - bonusBmxTracker:  deposit token stakedBmxTracker.
 *  - feeBmxTracker (sbfBMX): deposit tokens bonusBmxTracker + bnBMX.
 *    `depositBalances(user, bnBMX)` = snapshotPoints (staked multiplier points).
 *  - bnBMX: the multiplier-point token.
 */
export const BASE_STAKING = {
  stakedBmxTracker: getAddress("0x3085F25Cbb5F34531229077BAAC20B9ef2AE85CB"),
  bonusBmxTracker: getAddress("0x9A8f034Df900E58C55764fAAC867c5BA11A8F70f"),
  feeBmxTracker: getAddress("0x38E5be3501687500E6338217276069d16178077E"),
  bnBMX: getAddress("0x10AB197551BAB91f8B218dC9730AE0e43d893Db2"),
} as const;

/** Canonical Multicall3, same address on all six chains. Needed explicitly because the clients are
 *  built without a viem `chain` object (see clients.ts). */
export const MULTICALL3_ADDRESS = getAddress(
  "0xcA11bde05977b3631167028862bE2a173976CA11",
);

/** Burn / dead address — always excluded. */
export const DEAD_ADDRESS = getAddress(
  "0x000000000000000000000000000000000000dEaD",
);
export const ZERO_ADDRESS = getAddress(
  "0x0000000000000000000000000000000000000000",
);

/** Base oBMX option-token contract. Holds protocol BMX that is permanently locked (inaccessible /
 *  non-migratable) — ~272k BMX at July 2026, which is the delta between the raw circulating supply
 *  and the 2,711,068 migration pool. */
export const BASE_OBMX = getAddress("0x3Ff7AB26F2dfD482C40bDaDfC0e88D01BFf79713");

/** Per-chain addresses whose held BMX is locked/non-migratable. validate check (c) deducts their
 *  balances from the migratable supply alongside dead/zero. Every entry must be justified: BMX held
 *  here can never reach `migrate()`. */
export const LOCKED_BMX_HOLDERS: Partial<Record<ChainKey, Address[]>> = {
  base: [BASE_OBMX],
};

/**
 * Known protocol contracts to ALWAYS exclude from the holder set.
 * Trackers hold the staked deposit tokens as their own ERC20 balance; counting their self-balance
 * would double-count staked BMX. Extend this with any LP pairs / fee collectors discovered during
 * the audit pass (add the addresses here so exclusion is reproducible, not RPC-dependent).
 *
 * NOTE: this list (plus dead/zero) is the ONLY exclusion — there is no bytecode fallback (see
 * exclusions.ts: contract-account stakers keep their leaves). Any protocol contract missing from
 * this list gets a leaf, so enumerate them exhaustively.
 *
 * PRECONDITION: no address here may hold a staked position (staked BMX or points) — an excluded
 * staker gets no leaf and validate check (b)'s exact-match sums would fail. validate asserts this.
 */
export const KNOWN_EXCLUDED: Address[] = [
  BASE_STAKING.stakedBmxTracker,
  BASE_STAKING.bonusBmxTracker,
  BASE_STAKING.feeBmxTracker,
  BASE_STAKING.bnBMX,
  BASE_OBMX,
  DEAD_ADDRESS,
  ZERO_ADDRESS,
  // TODO: append known BMX/WETH LP pair addresses and BoardwalkFeeCollector addresses per chain
  //       once enumerated during the audit pass, so they are excluded reproducibly.
];

/** Lowercased set for fast membership tests. */
export const KNOWN_EXCLUDED_SET: Set<string> = new Set(
  KNOWN_EXCLUDED.map((a) => a.toLowerCase()),
);

/** Public RPC defaults. Production SHOULD override via env with private/archive endpoints. */
const DEFAULT_RPC: Record<ChainKey, string | undefined> = {
  ethereum: "https://ethereum-rpc.publicnode.com",
  base: "https://mainnet.base.org",
  fraxtal: "https://rpc.frax.com",
  ink: "https://rpc-gel.inkonchain.com",
  arbitrum: "https://arb1.arbitrum.io/rpc",
  // TODO: no vetted public Katana RPC baked in — MUST be supplied via RPC_KATANA.
  katana: undefined,
};

const RPC_ENV: Record<ChainKey, string> = {
  ethereum: "RPC_ETHEREUM",
  base: "RPC_BASE",
  fraxtal: "RPC_FRAXTAL",
  katana: "RPC_KATANA",
  ink: "RPC_INK",
  arbitrum: "RPC_ARBITRUM",
};

const SNAPSHOT_BLOCK_ENV: Record<ChainKey, string> = {
  ethereum: "SNAPSHOT_BLOCK_ETHEREUM",
  base: "SNAPSHOT_BLOCK_BASE",
  fraxtal: "SNAPSHOT_BLOCK_FRAXTAL",
  katana: "SNAPSHOT_BLOCK_KATANA",
  ink: "SNAPSHOT_BLOCK_INK",
  arbitrum: "SNAPSHOT_BLOCK_ARBITRUM",
};

const DEPLOY_BLOCK_ENV: Record<ChainKey, string> = {
  ethereum: "BMX_DEPLOY_BLOCK_ETHEREUM",
  base: "BMX_DEPLOY_BLOCK_BASE",
  fraxtal: "BMX_DEPLOY_BLOCK_FRAXTAL",
  katana: "BMX_DEPLOY_BLOCK_KATANA",
  ink: "BMX_DEPLOY_BLOCK_INK",
  arbitrum: "BMX_DEPLOY_BLOCK_ARBITRUM",
};

/** Resolve the RPC URL for a chain (env over default); throws if neither is set. */
export function rpcUrl(chain: ChainKey): string {
  const fromEnv = process.env[RPC_ENV[chain]];
  const url = fromEnv && fromEnv.trim() !== "" ? fromEnv.trim() : DEFAULT_RPC[chain];
  if (!url) {
    throw new Error(
      `No RPC URL for ${chain}: set ${RPC_ENV[chain]} (no public default available).`,
    );
  }
  return url;
}

/**
 * Resolve the snapshot block for a chain. Returns `"latest"` with a loud warning when unset —
 * production MUST pin a block on every chain so the snapshot is reproducible and tamper-evident.
 */
export function snapshotBlock(chain: ChainKey): bigint | "latest" {
  const raw = process.env[SNAPSHOT_BLOCK_ENV[chain]];
  if (!raw || raw.trim() === "") {
    console.warn(
      `[WARN] ${SNAPSHOT_BLOCK_ENV[chain]} is unset — using "latest" for ${chain}. ` +
        `PRODUCTION MUST PIN A BLOCK. The on-chain merkle root is one-shot and unrecoverable.`,
    );
    return "latest";
  }
  return BigInt(raw.trim());
}

/** Lower bound for Transfer-log discovery on a chain. Defaults to 0n (slow) when unset. */
export function deployBlock(chain: ChainKey): bigint {
  const raw = process.env[DEPLOY_BLOCK_ENV[chain]];
  if (!raw || raw.trim() === "") {
    console.warn(
      `[WARN] ${DEPLOY_BLOCK_ENV[chain]} is unset — log discovery starts from block 0 for ${chain} (slow).`,
    );
    return 0n;
  }
  return BigInt(raw.trim());
}

export function logChunkSize(): bigint {
  const raw = process.env.LOG_CHUNK_SIZE;
  return raw && raw.trim() !== "" ? BigInt(raw.trim()) : 50_000n;
}

export function multicallBatchSize(): number {
  const raw = process.env.MULTICALL_BATCH_SIZE;
  return raw && raw.trim() !== "" ? Number(raw.trim()) : 500;
}

/**
 * Supply constants.
 *  - MIGRATION_POOL_BWS: the pre-funded BWS pool, 2_711_068e18.
 *  - CREDIT_BPS: 16% voter credit — applied CONTRACT-SIDE (_pointsFor). The pipeline emits only the
 *    raw (account, snapshotBmx, snapshotPoints) leaves and never applies this. Kept here only so
 *    docs / validate can reference the on-chain factor.
 */
export const MIGRATION_POOL_BWS = 2_711_068n * 10n ** 18n;
export const CREDIT_BPS = 1_600n;
export const BPS = 10_000n;

/** Output directory (relative to snapshot). */
export const OUT_DIR = "out";
export const FIXTURES_DIR = "fixtures";

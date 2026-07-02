import { getAddress, parseAbiItem, type Address, type PublicClient } from "viem";
import { clientFor } from "./clients.js";
import {
  BMX_ADDRESS,
  CHAIN_KEYS,
  deployBlock,
  logChunkSize,
  snapshotBlock,
  type ChainKey,
} from "./config.js";
import { fileExists, outPath, readJson, writeJson } from "./io.js";

/** Transfer event, typed as an AbiEvent so viem can decode `from`/`to`/`value`. */
const TRANSFER_EVENT = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 value)",
);

/**
 * Build the candidate holder set for a chain.
 *
 * Two interchangeable sources (documented in README):
 *   (A) Log scan: chunked `eth_getLogs` over BMX `Transfer` events from the deploy block to the
 *       snapshot block, collecting every `from`/`to` ever seen. Reproducible given a pinned
 *       [deployBlock, snapshotBlock] range. Cached to out/holders-<chain>.json.
 *   (B) Input file: if out/holders-<chain>.json already exists, it is used as-is (lets an operator
 *       supply an indexer-derived holder list and skip the scan). Delete the file to force a rescan.
 *
 * The set is a superset of true holders (anyone who ever touched BMX). Balance reads at the
 * snapshot block (readBalances.ts) collapse zero-balance addresses out.
 *
 * @returns deduped, checksummed candidate addresses for the chain.
 */
export async function discoverHolders(chain: ChainKey): Promise<Address[]> {
  const cachePath = outPath(`holders-${chain}.json`);
  if (fileExists(cachePath)) {
    const cached = readJson<{ chain: string; holders: string[]; fromBlock?: string; toBlock?: string }>(cachePath);
    // A cache covering a narrower range than [deployBlock, snapshotBlock] silently misses holders
    // at either end, and the root is one-shot - refuse a stale range rather than under-discover.
    const pinned = snapshotBlock(chain);
    if (pinned !== "latest") {
      if (cached.toBlock === undefined || BigInt(cached.toBlock) < pinned) {
        throw new Error(
          `[${chain}] holder cache ${cachePath} covers blocks up to ${cached.toBlock ?? "<unknown>"}, ` +
            `below the pinned snapshot block ${pinned}. Delete the file to rescan, or supply an ` +
            `indexer export that covers the snapshot block and declares its "toBlock".`,
        );
      }
    }
    const lowerBound = deployBlock(chain);
    if (lowerBound > 0n && cached.fromBlock !== undefined && BigInt(cached.fromBlock) > lowerBound) {
      throw new Error(
        `[${chain}] holder cache ${cachePath} starts at block ${cached.fromBlock}, above the ` +
          `pinned deploy block ${lowerBound} - early holders would be missed. Delete the file to rescan.`,
      );
    }
    console.log(
      `[${chain}] using cached/input holder set: ${cached.holders.length} candidates (${cachePath})`,
    );
    return cached.holders.map((a) => getAddress(a));
  }

  const client = clientFor(chain);
  const token = BMX_ADDRESS[chain];
  const fromBlock = deployBlock(chain);
  const target = snapshotBlock(chain);
  const toBlock =
    target === "latest" ? await client.getBlockNumber() : target;
  const chunk = logChunkSize();

  console.log(
    `[${chain}] scanning BMX ${token} Transfer logs ${fromBlock}..${toBlock} (chunk ${chunk})`,
  );

  const holders = new Set<string>();
  for (let start = fromBlock; start <= toBlock; start += chunk) {
    const end = start + chunk - 1n > toBlock ? toBlock : start + chunk - 1n;
    const logs = await getTransferLogs(client, token, start, end);
    for (const log of logs) {
      const args = log.args as { from?: Address; to?: Address };
      if (args.from) holders.add(args.from.toLowerCase());
      if (args.to) holders.add(args.to.toLowerCase());
    }
    console.log(
      `[${chain}]   ${start}..${end}: +${logs.length} logs, ${holders.size} unique addresses so far`,
    );
  }

  const result = [...holders].map((a) => getAddress(a)).sort();
  writeJson(cachePath, {
    chain,
    token,
    fromBlock: fromBlock.toString(),
    toBlock: toBlock.toString(),
    holders: result,
  });
  console.log(`[${chain}] discovered ${result.length} candidates -> ${cachePath}`);
  return result;
}

async function getTransferLogs(
  client: PublicClient,
  token: Address,
  fromBlock: bigint,
  toBlock: bigint,
) {
  return client.getLogs({
    address: token,
    event: TRANSFER_EVENT,
    fromBlock,
    toBlock,
  });
}

/** CLI: discover for all chains (or a single chain via argv). */
async function main() {
  const only = process.argv[2] as ChainKey | undefined;
  const chains = only ? [only] : CHAIN_KEYS;
  for (const chain of chains) {
    await discoverHolders(chain);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}

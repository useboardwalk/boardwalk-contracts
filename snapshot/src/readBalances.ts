import { type Address, type PublicClient } from "viem";
import { clientFor, ERC20_ABI } from "./clients.js";
import {
  BMX_ADDRESS,
  multicallBatchSize,
  snapshotBlock,
  type ChainKey,
} from "./config.js";

export type BalanceMap = Map<string, bigint>;

/**
 * Read BMX `balanceOf` for every candidate on a chain, at the chain's snapshot block, via Multicall3.
 *
 * @param chain Chain key.
 * @param candidates Addresses to read (checksummed). Zero-balance results are dropped.
 * @returns Map keyed by LOWERCASED address -> wallet BMX balance (wei). Only non-zero entries.
 */
export async function readBalances(
  chain: ChainKey,
  candidates: Address[],
): Promise<BalanceMap> {
  const client = clientFor(chain);
  const token = BMX_ADDRESS[chain];
  const target = snapshotBlock(chain);
  const blockNumber =
    target === "latest" ? await client.getBlockNumber() : target;
  const batchSize = multicallBatchSize();

  const out: BalanceMap = new Map();
  for (let i = 0; i < candidates.length; i += batchSize) {
    const slice = candidates.slice(i, i + batchSize);
    const results = await multicallBalanceOf(client, token, slice, blockNumber);
    for (let j = 0; j < slice.length; j++) {
      const bal = results[j]!;
      if (bal > 0n) {
        out.set(slice[j]!.toLowerCase(), bal);
      }
    }
    console.log(
      `[${chain}]   balances ${i + slice.length}/${candidates.length}, ${out.size} non-zero`,
    );
  }
  console.log(
    `[${chain}] balanceOf @ block ${blockNumber}: ${out.size} non-zero holders`,
  );
  return out;
}

async function multicallBalanceOf(
  client: PublicClient,
  token: Address,
  accounts: Address[],
  blockNumber: bigint,
): Promise<bigint[]> {
  // allowFailure: false — fail loudly instead of silently dropping a holder on an RPC error.
  const results = await client.multicall({
    blockNumber,
    allowFailure: false,
    contracts: accounts.map((account) => ({
      address: token,
      abi: ERC20_ABI,
      functionName: "balanceOf" as const,
      args: [account] as const,
    })),
  });
  return results as bigint[];
}

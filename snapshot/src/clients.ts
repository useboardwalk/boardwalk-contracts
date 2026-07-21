import {
  createPublicClient,
  http,
  type Abi,
  type Address,
  type PublicClient,
} from "viem";
import { rpcUrl, type ChainKey } from "./config.js";

/** Minimal ERC20 ABI: only the reads this pipeline performs. */
export const ERC20_ABI = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "totalSupply",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "event",
    name: "Transfer",
    inputs: [
      { name: "from", type: "address", indexed: true },
      { name: "to", type: "address", indexed: true },
      { name: "value", type: "uint256", indexed: false },
    ],
  },
] as const satisfies Abi;

/** Minimal RewardTracker ABI: `depositBalances` + `claimable`. */
export const REWARD_TRACKER_ABI = [
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
  {
    type: "function",
    name: "claimable",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const satisfies Abi;

/**
 * Build a public client for a chain. We do NOT pass a `chain` object — the pipeline only needs raw
 * JSON-RPC reads, and avoiding the viem chain registry keeps Katana (and any non-registered chain)
 * working from a bare RPC URL. The trade-offs of a chain-less client:
 *  - explicit `client.multicall` calls must pass `multicallAddress: MULTICALL3_ADDRESS` (viem
 *    otherwise resolves it from `chain.contracts`, which does not exist here);
 *  - no client-level `batch.multicall` (same reason); the http transport's JSON-RPC batching
 *    still folds concurrent reads into one request.
 */
export function clientFor(chain: ChainKey): PublicClient {
  return createPublicClient({
    transport: http(rpcUrl(chain), {
      batch: true,
      retryCount: 3,
      retryDelay: 250,
      timeout: 30_000,
    }),
  });
}

export type { Address };

import { aggregate } from "./aggregate.js";
import { buildTree } from "./buildTree.js";

/**
 * End-to-end orchestrator: discover -> balances -> staked/points -> aggregate -> tree.
 *
 * discoverHolders/readBalances/readStakedPoints are invoked inside aggregate(); this just chains
 * aggregate() into buildTree() and prints the resulting root.
 *
 * Run with a pinned SNAPSHOT_BLOCK_* on every chain. Raw discovery results are cached under out/
 * (holders-<chain>.json) for reproducibility.
 */
async function main(): Promise<void> {
  console.log("[index] starting full snapshot run...");
  const entries = await aggregate();
  const root = buildTree(entries);
  console.log(`\n[index] done. ${entries.length} staker leaves. merkle root: ${root}`);
  console.log("[index] next: run `npm run validate` before publishing the root on-chain.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

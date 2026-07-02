import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { type AggregatedEntry } from "./aggregate.js";
import { outPath, readJson, writeJson, writeText } from "./io.js";
import { LEAF_ENCODING, type LeafValue } from "./leaves.js";

export interface ProofEntry {
  account: string;
  snapshotBmx: string;
  snapshotPoints: string;
  proof: string[];
}

/**
 * Build the StandardMerkleTree from out/aggregate.json and emit:
 *   out/tree.json   — full tree.dump() (lets anyone re-derive proofs/root offline)
 *   out/root.txt    — the 0x merkle root, one line
 *   out/proofs.json — [{account, snapshotBmx, snapshotPoints, proof}]
 *
 * The leaf values are [account, snapshotBmx, snapshotPoints] encoded as ["address","uint256",
 * "uint256"] — identical to the on-chain encoding.
 *
 * @param entries Optional in-memory entries (used by the orchestrator); otherwise reads aggregate.json.
 * @returns the 0x merkle root.
 */
export function buildTree(entries?: AggregatedEntry[]): string {
  const src =
    entries ??
    readJson<{ entries: AggregatedEntry[] }>(outPath("aggregate.json")).entries;

  if (src.length === 0) {
    throw new Error(
      "No entries to build a tree from. Run the snapshot (or aggregate) first.",
    );
  }

  const values: LeafValue[] = src.map((e) => [
    e.account,
    e.snapshotBmx,
    e.snapshotPoints,
  ]);

  const tree = StandardMerkleTree.of(values, [...LEAF_ENCODING]);

  const proofs: ProofEntry[] = [];
  for (const [i, value] of tree.entries()) {
    proofs.push({
      account: value[0]!,
      snapshotBmx: value[1]!,
      snapshotPoints: value[2]!,
      proof: tree.getProof(i),
    });
  }

  writeJson(outPath("tree.json"), tree.dump());
  writeText(outPath("root.txt"), tree.root + "\n");
  writeJson(outPath("proofs.json"), proofs);

  console.log(`[tree] root ${tree.root}`);
  console.log(`[tree] ${proofs.length} leaves -> out/tree.json, out/root.txt, out/proofs.json`);
  return tree.root;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    buildTree();
  } catch (e) {
    console.error(e);
    process.exit(1);
  }
}

import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { getAddress } from "viem";
import { outPath, readJson } from "./io.js";
import { LEAF_ENCODING, type LeafValue } from "./leaves.js";

/**
 * CLI: `eligibility <address>`. Self-check for a user — prints snapshotBmx / snapshotPoints and the
 * proof, then locally re-verifies via StandardMerkleTree.verify against the published root so the
 * user can confirm their entry is genuinely committed before migrating. Exit non-zero if not found
 * or if local verification fails.
 */
function main(): void {
  const arg = process.argv[2];
  if (!arg) {
    console.error("usage: tsx src/checkEligibility.ts <address>");
    process.exit(2);
  }
  let target: string;
  try {
    target = getAddress(arg);
  } catch {
    console.error(`invalid address: ${arg}`);
    process.exit(2);
    return;
  }

  const dump = readJson<ReturnType<StandardMerkleTree<LeafValue>["dump"]>>(
    outPath("tree.json"),
  );
  const tree = StandardMerkleTree.load(dump);

  for (const [i, value] of tree.entries()) {
    if (getAddress(value[0]!) === target) {
      const proof = tree.getProof(i);
      const ok = StandardMerkleTree.verify(
        tree.root,
        [...LEAF_ENCODING],
        value,
        proof,
      );
      console.log(`address:        ${value[0]}`);
      console.log(`snapshotBmx:    ${value[1]}`);
      console.log(`snapshotPoints: ${value[2]}`);
      console.log(`root:           ${tree.root}`);
      console.log(`proof:          ${JSON.stringify(proof)}`);
      console.log(`localVerify:    ${ok ? "PASS" : "FAIL"}`);
      if (!ok) process.exit(1);
      return;
    }
  }

  console.log(`address:     ${target}`);
  console.log(
    `eligibility: NOT IN TREE — migrates 1:1 and still earns the 16% base voter-point credit on-chain (no leaf needed; pass 0, 0, empty proof).`,
  );
  process.exit(1);
}

main();

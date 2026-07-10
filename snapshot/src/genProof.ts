import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { getAddress } from "viem";
import { outPath, readJson } from "./io.js";
import { LEAF_ENCODING, type LeafValue } from "./leaves.js";

/**
 * CLI: `proof <address>`. Loads out/tree.json, finds the leaf for <address>, prints its values and
 * proof. Exits non-zero if the address is not in the tree.
 */
function main(): void {
  const arg = process.argv[2];
  if (!arg) {
    console.error("usage: tsx src/genProof.ts <address>");
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
      console.log(
        JSON.stringify(
          {
            account: value[0],
            snapshotBmx: value[1],
            snapshotPoints: value[2],
            proof,
            root: tree.root,
          },
          null,
          2,
        ),
      );
      return;
    }
  }

  console.error(
    `${target} not in tree (absent = migrates 1:1 and still earns the 16% base voter-point credit on-chain; no leaf needed).`,
  );
  process.exit(1);
}

main();

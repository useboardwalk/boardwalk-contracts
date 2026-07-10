/**
 * Leaf encoding shared across the pipeline. MUST mirror BwsMigration.migrate exactly:
 *
 *   leaf = keccak256(bytes.concat(keccak256(abi.encode(address account, uint256 snapshotBmx,
 *                                                       uint256 snapshotPoints))))
 *
 * verified with OZ MerkleProof.verify (sorted/commutative pair hashing). That is precisely OZ
 * `@openzeppelin/merkle-tree` StandardMerkleTree with leaf encoding ["address","uint256","uint256"].
 */
export const LEAF_ENCODING = ["address", "uint256", "uint256"] as const;

/** A single tree value: [account, snapshotBmx (wei decimal string), snapshotPoints (wei decimal string)]. */
export type LeafValue = [string, string, string];

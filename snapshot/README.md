# BMX → BWLK snapshot pipeline

Builds the one-shot merkle root + per-account proofs that `src/token/BwsMigration.sol` consumes.

It's **stakers-only**. BWLK is always 1:1 with surrendered BMX, and every migrator earns a 16% base credit on-chain automatically (`_pointsFor`, no leaf required) — so non-stakers need no entry. A leaf exists only to carry a prior staker's *existing* points across the migration.

> The on-chain root is set **once** and can't be changed. Pin the blocks, run `npm run validate`, and eyeball `out/snapshot.csv` before publishing.

## Leaf

`StandardMerkleTree.of(values, ["address","uint256","uint256"])` from `@openzeppelin/merkle-tree`, one value per staker: `[account, snapshotBmx, snapshotPoints]` (amounts in wei). This matches the contract's `keccak256(bytes.concat(keccak256(abi.encode(...))))` + OZ `MerkleProof.verify`; hashing is never hand-rolled.

Per staker, at the snapshot block:
- `snapshotBmx` — Base staked BMX (`stakedBmxTracker.depositBalances(user, BMX)`); the carry-ratio denominator.
- `snapshotPoints` — staked points (`sbfBMX.depositBalances(user, bnBMX)`).

Only stakers (staked BMX or points > 0) get a leaf. **Exclusions are allowlist-only** — dead/zero plus `KNOWN_EXCLUDED` (trackers, bnBMX, LP pairs, fee collectors). There is deliberately **no bytecode check**: `migrate` has no EOA gate, so Safe- and EIP-7702-held stakes keep their leaves (dropping them would forfeit real points and break the validate (b) sums).

## Blocks

Both pinned via `SNAPSHOT_BLOCK_<chain>` (unset falls back to `latest` with a loud warning — never in production):
- **Audit block** — an earlier pinned block for a reproducibility pass: delete `out/holders-*.json`, re-run, confirm a byte-identical root. Doesn't feed the chain.
- **Go-live block** — the block just before the migrator opens; feeds the real root. Stakers must stay staked through it.

## Run

Node ≥ 20.

```bash
cd snapshot
npm install
cp .env.example .env   # private RPCs + pinned SNAPSHOT_BLOCK_* + BMX_DEPLOY_BLOCK_*
npm run snapshot       # discover → balances → points → aggregate → tree
npm run validate       # pre-publish gate; exits non-zero on any failure
```

Also: `npm run proof <addr>`, `npm run eligibility <addr>`, `npm run tree`, `npm run build:fixture`.

Discovery scans BMX `Transfer` logs from `BMX_DEPLOY_BLOCK_<chain>` to the snapshot block (pin the deploy block or it scans from 0). Drop an `out/holders-<chain>.json` (`{holders, toBlock}`) to skip the scan — used only if its `toBlock` covers the snapshot block.

## Outputs (`out/`, gitignored)

`root.txt` (publish via `setMerkleRoot`), `proofs.json` (frontend), `tree.json` (re-derive offline), `snapshot.csv` (audit, one column per chain). Committed `fixtures/` (from `npm run build:fixture`, no RPC) feed the Solidity tests.

## Before `setMerkleRoot`

`npm run validate` checks:
- **(a)** a random sample of leaves re-reads identically against live chains;
- **(b)** aggregate `snapshotBmx`/`snapshotPoints` equal the trackers' `totalDepositSupply` (nothing dropped, and no `KNOWN_EXCLUDED` address is itself staked);
- **(c)** the `2,711,068e18` pool ≥ total migratable BMX (per-chain supply minus dead/zero and the `LOCKED_BMX_HOLDERS` ~272k Base oBMX).

Then by hand: pin every chain's block, use private/archive RPCs (incl. `RPC_KATANA`), byte-check the `src/config.ts` addresses and that `KNOWN_EXCLUDED` lists every LP pair + fee collector, skim the largest rows of `snapshot.csv`, and re-run from a second RPC — the root must match byte-for-byte.

## Production snapshot (2026-07-21)

Taken at 17:00 EEST (unix `1784642400`), pinned to the last block at or before that time on each
chain: Ethereum 25581555, Base 48926526, Fraxtal 38915844, Katana 37899589, Ink 51143989,
Arbitrum 486205179.

Root `0x277d55442de15e03601d65ae41ae73376fd12d7c3bfd4cbf73de07c9e4ccd895`, 280 leaves. Sums match
the trackers at the Base block exactly (staked `1836801799459244820978405`, points
`2304262956333856652682556`), and a second run with independent discovery gave the same root.

`prod-2026-07-21/` keeps the published artifacts (`out/` gets overwritten by later runs):
root.txt, tree.json, proofs.json, community-snapshot.csv (sorted by stake, human units),
base-staking-verification.json, and the base-stakers.json discovery cache.

To check an address: search community-snapshot.csv, or copy the artifacts into `out/` and run
`npm run eligibility <addr>`. Addresses without a leaf simply weren't staked at the snapshot block.

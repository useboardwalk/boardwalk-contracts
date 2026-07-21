import { type Address, type PublicClient } from "viem";
import { clientFor, REWARD_TRACKER_ABI } from "./clients.js";
import {
  BASE_STAKING,
  BMX_ADDRESS,
  MULTICALL3_ADDRESS,
  multicallBatchSize,
  snapshotBlock,
} from "./config.js";

export interface StakedRead {
  /** stakedBmxTracker.depositBalances(user, BMX) — staked BMX component of snapshotBmx (wei). */
  stakedBmx: bigint;
  /** feeBmxTracker(sbfBMX).depositBalances(user, bnBMX) — staked (compounded) points (wei). */
  stakedPoints: bigint;
  /** bonusBmxTracker.claimable(user) — accrued but not-yet-compounded points (wei). */
  pendingPoints: bigint;
}

export type StakedMap = Map<string, StakedRead>;

/**
 * Read Base staking data for a set of users via Multicall3 at the Base snapshot block.
 *
 *   stakedBmx     = STAKED_BMX_TRACKER.depositBalances(user, BMX)
 *   stakedPoints  = feeBmxTracker (sbfBMX).depositBalances(user, BN_BMX)
 *   pendingPoints = bonusBmxTracker.claimable(user)
 *
 * stakedBmx feeds the points-ratio denominator. snapshotPoints = stakedPoints + pendingPoints:
 * pending points would have compounded into the fee tracker eventually, so the snapshot carries
 * them rather than punishing stakers who never pressed compound.
 *
 * @param users Addresses to read (checksummed).
 * @returns Map keyed by LOWERCASED address -> StakedRead. Only entries with a non-zero
 *          stakedBmx, stakedPoints, or pendingPoints are included.
 */
export async function readStakedPoints(users: Address[]): Promise<StakedMap> {
  const client = clientFor("base");
  const target = snapshotBlock("base");
  const blockNumber =
    target === "latest" ? await client.getBlockNumber() : target;
  const batchSize = multicallBatchSize();

  const bmx = BMX_ADDRESS.base;
  const { stakedBmxTracker, bonusBmxTracker, feeBmxTracker, bnBMX } = BASE_STAKING;

  const out: StakedMap = new Map();
  for (let i = 0; i < users.length; i += batchSize) {
    const slice = users.slice(i, i + batchSize);

    const stakedResults = await multicallDepositBalances(
      client,
      stakedBmxTracker,
      slice.map((u) => [u, bmx] as const),
      blockNumber,
    );
    const pointsResults = await multicallDepositBalances(
      client,
      feeBmxTracker,
      slice.map((u) => [u, bnBMX] as const),
      blockNumber,
    );
    const pendingResults = await multicallClaimable(
      client,
      bonusBmxTracker,
      slice,
      blockNumber,
    );

    for (let j = 0; j < slice.length; j++) {
      const stakedBmx = stakedResults[j]!;
      const stakedPoints = pointsResults[j]!;
      const pendingPoints = pendingResults[j]!;
      if (stakedBmx > 0n || stakedPoints > 0n || pendingPoints > 0n) {
        out.set(slice[j]!.toLowerCase(), { stakedBmx, stakedPoints, pendingPoints });
      }
    }
    console.log(
      `[base]   staked/points ${i + slice.length}/${users.length}, ${out.size} with stake`,
    );
  }
  console.log(
    `[base] staked BMX + points (incl. pending) @ block ${blockNumber}: ${out.size} staking users`,
  );
  return out;
}

async function multicallDepositBalances(
  client: PublicClient,
  tracker: Address,
  pairs: ReadonlyArray<readonly [Address, Address]>,
  blockNumber: bigint,
): Promise<bigint[]> {
  // allowFailure: false — a failed call (or a chunk-level RPC error, which viem would otherwise
  // surface as per-call failures for the whole slice) throws instead of being silently coerced to
  // zero and baked into the one-shot root as a zeroed leaf.
  const results = await client.multicall({
    blockNumber,
    allowFailure: false,
    // The client has no `chain` object, so viem cannot resolve Multicall3 on its own.
    multicallAddress: MULTICALL3_ADDRESS,
    contracts: pairs.map(([account, depositToken]) => ({
      address: tracker,
      abi: REWARD_TRACKER_ABI,
      functionName: "depositBalances" as const,
      args: [account, depositToken] as const,
    })),
  });
  return results as bigint[];
}

async function multicallClaimable(
  client: PublicClient,
  tracker: Address,
  accounts: ReadonlyArray<Address>,
  blockNumber: bigint,
): Promise<bigint[]> {
  // allowFailure: false — same rationale as multicallDepositBalances.
  const results = await client.multicall({
    blockNumber,
    allowFailure: false,
    multicallAddress: MULTICALL3_ADDRESS,
    contracts: accounts.map((account) => ({
      address: tracker,
      abi: REWARD_TRACKER_ABI,
      functionName: "claimable" as const,
      args: [account] as const,
    })),
  });
  return results as bigint[];
}

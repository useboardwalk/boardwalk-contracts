import { type Address } from "viem";
import { DEAD_ADDRESS, KNOWN_EXCLUDED_SET, ZERO_ADDRESS } from "./config.js";

/**
 * Decide whether an address must be excluded from the snapshot tree.
 *
 * Excluded ONLY when:
 *  - it is the zero or dead address, or
 *  - it is in the known protocol-contract allowlist (trackers, bnBMX, LP pairs, fee collectors).
 *
 * There is intentionally NO bytecode (`code.length`) check. `BwsMigration.migrate` has no EOA gate,
 * so contract accounts (Safes, smart wallets) migrate like anyone else, and EIP-7702-delegated EOAs
 * carry `0xef0100...` code while remaining ordinary key-controlled accounts. A leaf for a genuinely
 * unclaimable contract is harmless (migrate binds to `msg.sender` and pays 1:1 from the same pool),
 * while a missing leaf permanently forfeits a real staker's carried points — the root is one-shot.
 * Excluding stakers on bytecode would also break validate check (b), which reconciles the leaf sum
 * against `stakedBmxTracker.totalDepositSupply(BMX)`.
 *
 * @param addr Candidate holder address.
 * @returns true if the address must be excluded.
 */
export function isExcluded(addr: Address): boolean {
  const lower = addr.toLowerCase();
  if (lower === DEAD_ADDRESS.toLowerCase() || lower === ZERO_ADDRESS.toLowerCase()) {
    return true;
  }
  return KNOWN_EXCLUDED_SET.has(lower);
}

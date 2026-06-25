# Boardwalk Launchpad — Project Instructions

## Architecture Reference

The canonical technical spec is at `SPEC.md`. Reference it for design decisions and invariants.

## Critical Design Invariants

These MUST be maintained across all code changes:

### Tax System
- Universal tax on ALL non-exempt transfers (no `isPair` mapping)
- Tax exemption list at init includes: [PresaleManager, VestingStream, LPStaking, FeeDistributor, BoardwalkLPManager, BoardwalkFeeCollector, IntegratorFeeCollector*] (* conditional on chain having a non-zero `integratorBps`)
- Post-init mutations are `feeDistributor`-only and limited to a **single** self-sovereign rotation flow: `setFeeCollector` (boardwalk migration). Rotates the exempt flag atomically with the role address; `IBoardwalkToken.isExempt(newAddress) == false` is enforced to prevent exempt-list aliasing. `IntegratorFeeCollector` is **immutable** — its exempt status cannot be re-pointed by anyone.
- Anti-whale: configurable per-launch via `LaunchFactory.executeSetAntiWhale(taxBps, duration)`. Bounds: `taxBps ∈ [500, 4000]` (5%–40%), `duration ∈ [5 min, 90 min]`. Frozen per-clone at `BoardwalkToken.initialize`. `baseTaxBps <= antiWhaleTaxBps` enforced
- `liquiditySeedTime == 0` means no tax (pre-seed)
- Token calls `FeeDistributor.onTaxReceived(amount)` as callback during `_update`
- BoardwalkLPManager provides tax-exempt LP add/remove (wrapper pattern)
- BoardwalkFeeCollector IS tax-exempt (uses standard swap variant)

### Fee Distribution
- Fee BPS are FROZEN per-launch (immutable). The integrator BPS is additionally FROZEN at the FACTORY level — `INTEGRATOR_BPS` is an immutable on `LaunchFactory` set once in the constructor; the admin's `executeSetFeeDefaults` can ONLY tune issuer/boardwalk/incentive/referrer (the four mutable buckets) for FUTURE launches. Per-chain BPS values are configured at deploy time and live in the public protocol docs; the technical spec only documents the buckets and bounds.
- Bounds enforced in `_validateFeeDefaults`: issuer ∈ [10, 80], boardwalk ∈ [10, 50], incentive ≤ 50, referrer ≤ 10 and ≤ boardwalk, `INTEGRATOR_BPS` ≤ 50. `total == issuer + boardwalk + incentive + INTEGRATOR_BPS`. Referrer carve-out: when a referrer is set, `boardwalkEffective = boardwalk - referrer`. Total tax stays at the configured BPS regardless. Integrator and referrer can coexist.
- LP fees forwarded to LPStaking via `notifyFees()` (try/catch, pendingLpFees retry). When `totalWeight == 0`, LPStaking BURNS the inbound to DEAD and emits `FeesLost` (so a first staker after dormancy cannot harvest fees that arrived before they staked); the FD-side `try` still succeeds, so `pendingLpFees` is NOT incremented in that path
- Boardwalk fees forwarded to FeeCollector via `receiveFees()` (try/catch, pendingBoardwalkFees retry)
- **Integrator fees forwarded as a single bucket to the immutable chain-level `IntegratorFeeCollector` via `receiveFees(token, amount)` (try/catch, `pendingIntegratorFees` retry).** FeeDistributor grants the collector max allowance at init for the pull pattern. The collector splits the bucket internally per its frozen `integratorSplits[]`; integrators claim via `claimSingular` / `claimBatch` (rate-limited to 25%/24h per slot per token, swapped to raise token via the standard router).
- Issuer claims as raise token (per-recipient 10% daily rate limit, slippage protection)
- Referrer claims directly via `claimReferrerFees()` (no rate limit)
- FeeDistributor uses regular `swapExactTokensForTokens` (it IS exempt)
- IntegratorFeeCollector uses regular `swapExactTokensForTokens` (it IS exempt)
- FeeCollector uses `swapExactTokensForTokensSupportingFeeOnTransferTokens` (NOT exempt)

### LP Staking
- ZERO admin functions (fully immutable after init)
- Weekly fee epochs anchored to `block.timestamp` (trigger time)
- Continuous vesting: `baseVestingRate * elapsed` (24h delay from seed)
- Multiplier points: 100% APR, proportional burn on withdraw
- Vesting rewards LOST during zero-staker periods (lastRewardUpdate advances)
- Fee notifications during zero-staker periods are BURNED to `DEAD_ADDRESS` and emit `FeesLost` (post-audit-fix: a first staker after dormancy cannot windfall pre-existing fees)
- 1e30 PRECISION for reward accumulator

### Presale
- O(1) per-user `weightedWeth` tracking with `totalWeightedWeth` normalization
- 10% early bird bonus at t=0, linearly to 0% at deadline
- Mint capped at TOTAL_SUPPLY (10 billion)
- Only PresaleManager can call `token.mint()` and `token.setLiquiditySeedTime()`
- Seed delay: 1 hour after presale ends
- 7-day cliff for presale claims from seed time

### Paths
- EXPRESS: 24h, 50% presale/50% liquidity, no vesting, no referrer, 1 fee recipient, starts immediately
- ADVANCED: 7d default (2d-14d admin range), 25-50% presale (divisible by 5), up to 5 vesting recipients (referrer can be included), optional referrer, up to 4 fee recipients, 24hr delay before sale starts

### Admin / Timelock
- All admin functions use `Timelocked` base (signal/execute/cancel)
- Default delay: 7d. Overrides: **14d** for `IntegratorFeeCollector.CHANGE_ADDRESS(slotIdx)` slot rotation; **21d** for governance-sensitive `GovernanceVoter` actions. 7-day expiry window after delay
- Fee recipient address changes: each role changes their own only (issuer / referrer / per-slot integrator)
- Claims go to OLD address until execute() is called
- **Self-sovereign**: `IntegratorFeeCollector.signalChangeAddress` / `cancelChangeAddress` gate on `msg.sender == integrators[slot]` (auto-derived from `_slotPlusOne` reverse map). `executeChangeAddress(slotIdx, newAddress)` is permissionless after delay (anyone can poke). `_authAdmin` reverts to close the generic `signalAction` back door. The 14-day delay (`ROTATION_DELAY`) is hardcoded into the explicit-delay `_signal(action, dataHash, ROTATION_DELAY)` overload — NOT routed through `_actionDelay` override, because the per-slot action key `keccak256(abi.encode(ACTION_CHANGE_ADDRESS, slotIdx))` would never match a bare-hash check. EOA / non-Timelocked slot-holders cannot shortcut the protocol-level minimum. Execute rejects `address(0)` and `newAddress` already taken by another slot (preserves reverse-map injectivity)
- **Single chain-level collector**: one `IntegratorFeeCollector` per chain, immutable address, frozen splits. Replaces the per-launch partner-controlled per-role collector pattern. No cross-clone migration helpers needed (the collector is global, not per-clone)
- **Owner-controlled**: `SET_ANTI_WHALE` (factory-level, future-launches only)

### Cross-Chain Membership NFT (CCIP bridge)
- Boardwalk Club (SeaDrop on Base, immutable, ids 1–224) bridges via Chainlink CCIP, **hub-and-spoke through Base only**: `BoardwalkClubLockbox` (Base, lock/release with `locked[id]` escrow accounting) + `BoardwalkClubMirror` (spokes, burn/mint transferable ERC721 with the original's name/symbol/URIs). Shared plumbing in `BoardwalkClubBridgeBase`
- Invariant: per token id, exactly one live representation — the original with a holder, or (while `locked`) exactly one spoke mirror. Release requires `locked[id]` (a peer can only release what `bridge` escrowed)
- Mirror peers are pinned to the Base selector at the type level (`OnlyBaseSelector`); lockbox wiring is one-shot `initializePeers`, later changes via typed `SET_PEER(selector)` timelock (7d). `removePeer` is the instant owner kill switch. Generic `signalAction` AND burn machinery are sealed (`_authAdmin` reverts)
- `bridge()` is `payable` — documented carve-out: caller pays the CCIP fee in native (quote via `quoteBridge`), excess refunded, exactly the quoted fee forwarded to the router. Effects (escrow/burn) land before router calls; refund is terminal
- Mirror `supportsInterface` is hardcoded `pure` (CCIPReceiver v1.6.4) and MUST return true for `0x85572ffb` — a false return makes the offramp mark deliveries SUCCESS without minting (vacuous success). The 30-day `FORCE_UNLOCK(tokenId, to)` on the lockbox is the sole backstop for that failure mode (and deprecated lanes); it is the only path that releases a `locked` original. The recipient is an explicit `to` (the rightful claimant may be a spoke secondary buyer, unknowable on Base) — verified off-chain, committed at signal time, adjudicated by the 30-day public window; bridging a live representation back defeats a wrongful signal (release cancels it). Signaling requires the token escrowed (no pre-arming the clock), and it must only target a CCIP-SUCCESS (vacuous) message or deprecated lane — never a FAILED-replayable one (manual re-execution recovers those; force-unlocking them double-mints)
- Spoke `nftCollection` migrates to the mirror via the existing `SET_NFT_COLLECTION` timelocks; the deprecated soulbound `BoardwalkClub` airdrop contract stays deployed but stops gating. Base keeps the original collection as `nftCollection`

### Cross-Chain Revenue Bridging
- Weekly, each non-Base chain bridges 100% of its `BoardwalkFeeCollector` revenue (the chain's raise token) to Base, landing as **WETH** in the Base FeeCollector (unchanged; 30/70 split applies). Triggered by an automated keeper (cron hot key) through on-chain contracts — never a wallet. Two contracts in `src/crosschain/`: a single generic `RevenueBridger` on every non-Base lane (ETH/Ink/Arbitrum pure Across V4, Katana Symbiosis, Fraxtal Glacis — all via the per-chain LiFi Diamond) and `BaseRevenueSwapper` (Base, delivery target for ALL lanes, rescue-capable)
- `RevenueBridger.bridgeToBase(amount, lifiCalldata)` is bridge-keeper-gated, nonReentrant, **payable** (the route's native fee — e.g. the Fraxtal/Glacis GMP fee in native FRAX — is the keeper's `msg.value`, forwarded to the Diamond with any unconsumed excess refunded to the keeper; pure ERC20 lanes pass `msg.value == 0`; an unconditional `receive()` accepts the Diamond's excess-fee refund): (1) call target is the immutable per-chain LiFi Diamond + an allowlisted facet selector (one shape per lane matching `HAS_SOURCE_SWAPS`: pure Across V4 `0xa1f1ce43` on ETH/Ink/Arbitrum, Symbiosis `0x6e067161` on Katana, Glacis `0x9c4b6dd9` on Fraxtal); (2) calldata pinning via `abi.decode(lifiCalldata[4:], (ILiFi.BridgeData))` — `receiver == swapper`, `destinationChainId == 8453`, `hasDestinationCall == false`, `hasSourceSwaps == HAS_SOURCE_SWAPS` (closes wrong-shape selector mis-curation); on pure Across V4 also pins `AcrossV4Data.refundAddress == address(this)` (load-bearing — closes the forced-expiry self-refund that bypasses the other pins), `sendingAssetId`/`receivingAssetId`, the `outputAmount` floor (`MAX_FEE_BPS`), and `receiverAddress`; on composed lanes (Symbiosis/Glacis) pins only the `requiresDeposit` legs (summed `fromAmount == amount`), never the post-swap `BridgeData.sendingAssetId`/`minAmount`; (3) exact-approve the Diamond for exactly `amount`, call, reset to 0, assert balance Δ ≤ amount (the direct counter to the standing-infinite-approval class behind both historical LiFi exploits — do NOT use the FeeCollector's standing max-approval idiom here)
- **Per-lane trust**: ETH/Ink/Arbitrum delivery is pinned on-chain (residual = `MAX_FEE_BPS` spread + LiFi-Diamond upgrade risk vs. the standing balance; forced expiry is liveness, not loss). Katana (Symbiosis) and Fraxtal (Glacis) delivery is keeper-trusted (the composed facet ignores `BridgeData` for routing — destination lives in keeper `metaRoute`/`GlacisData` calldata). The Base swap leg (`BaseRevenueSwapper.swapAndForward`, keeper-supplied `tokenIn` + 0x calldata + `minOut`) is keeper-trusted, bounded by `minOut` (consistent with the existing FeeCollector keeper-swap model — no on-chain rate floor); `tokenIn` is pinned `!= WETH` so keeper calldata can never approve/pull the contract's bridged WETH, and the output is always WETH to the immutable `FEE_COLLECTOR`. Every keeper-trusted leg is bounded to the **standing balance** by operational controls (load-bearing, not contract logic): authority split (source FeeCollector `keeper` ≠ bridge key, isolated hosts) + accrual gating (don't `forwardRevenue` until the prior bridge lands on Base) + outflow alerting + instant `revokeKeeper`
- **Instant `revokeKeeper`** (owner-only, sets keeper to `address(0)`) is a documented exception to the all-admin-actions-Timelocked invariant (precedent: lockbox `removePeer`); `setKeeper` stays 7d. Generic `signalAction` AND burn machinery are sealed (`_authAdmin` reverts); only typed actions mutate state (`RevenueBridger`: `SET_KEEPER`, `SET_SELECTOR`, `RESCUE`; swapper: `SET_KEEPER`, `RESCUE`). The single `RESCUE(token, to, amount)` rescues native when `token == address(0)`, else the ERC20. The permissionless `forwardWeth` (swapper) is `nonReentrant` so it cannot fire inside `swapAndForward`'s 0x call and disturb its WETH balance-delta read
- **Invariant (source chains)**: `governanceVault == address(0)` forever on ETH/Ink/Arbitrum/Katana/Fraxtal — a set vault diverts 70% of `forwardRevenue` past the bridger. Never call `executeSetGovernanceVault` there; alert on `GovernanceVaultUpdated`
- **Invariant (Base)**: nothing but WETH may be addressed to the Base FeeCollector (it has no rescue). Made structural — all lanes deliver to the rescue-capable `BaseRevenueSwapper`; only its WETH (`swapAndForward`'s full-balance forward / permissionless `forwardWeth`) ever reaches the FeeCollector
- Per-chain config in `script/CrossChainConfig.sol` (the per-chain LiFi Diamond is NOT one canonical address — Ink/Katana differ and the canonical address has no code there; byte-verify all at build); deploy via `script/06_DeployRevenueBridging.s.sol` (Base swapper first, then each non-Base lane pinned to it as `BASE_DESTINATION`)

## Build Order

1. Interfaces (all)
2. Timelocked.sol
3. BoardwalkToken.sol
4. FeeDistributor.sol
5. LPStaking.sol
6. VestingStream.sol
7. PresaleManager.sol
8. LaunchFactory.sol
9. BoardwalkLPManager.sol
10. BoardwalkFeeCollector.sol
11. IntegratorFeeCollector.sol (per-chain protocol singleton)
12. NFT bridge: BoardwalkClubBridgeBase.sol → BoardwalkClubLockbox.sol (Base) / BoardwalkClubMirror.sol (spokes)
13. Cross-chain revenue bridging: RevenueBridger.sol (every non-Base lane: ETH/Ink/Arbitrum/Katana/Fraxtal) / BaseRevenueSwapper.sol (Base)
14. DEX contracts (fork)

## Solidity Code Standards

- Solidity 0.8.28, `evm_version = "cancun"`
- ALL errors: custom errors only (no `require` with strings)
- ALL transfers: SafeERC20 (no raw `transfer`/`transferFrom`)
- ALL imports: named imports (`import {X} from "..."`)
- NO `receive()`, `fallback()`, `payable`, or `msg.value`. Carve-outs: `GovernanceVoter`/`LPLocker` `receive()` (WETH unwrap), `BoardwalkClubBridgeBase.bridge()` payable (native CCIP fee, excess refunded), and `RevenueBridger.bridgeToBase` payable (the native LiFi route fee — e.g. the Fraxtal/Glacis GMP fee in native FRAX — passed as the keeper's `msg.value`, forwarded to the Diamond with any unconsumed excess refunded to the keeper, plus an **unconditional** `receive()` to accept the Diamond's excess-fee refund). The `BaseRevenueSwapper` is non-payable (`rescueNative` only backstops forcibly-sent native).
- NO `tx.origin` for authentication
- NatSpec on all public/external functions

### Interface Accuracy

Interfaces in `src/interfaces/` mirror the external integration ABI of their corresponding production contracts. They declare:

- All external/public functions and auto-generated public-getter signatures (state, constants, immutables)
- All custom errors reachable from external calls
- All events emitted by the contract
- All structs and enums used in external function parameters or return values

Whenever a contract's external surface changes, update the matching interface in the same change. An interface accuracy audit is performed before each release to catch drift.

This codebase does NOT require contracts to inherit their canonical interface (`contract Foo is IFoo`). The compile-time enforcement that inheritance provides is deliberately traded for less ceremony and lower mid-audit churn risk.

Carve-outs:
- When extending a standard interface (e.g. OZ `IERC20`), the canonical interface declares only protocol-specific additions; the standard ABI is inherited from the standard interface. Example: `IBoardwalkToken` declares `isExempt`, `feeDistributor`, `mint`, `setLiquiditySeedTime`, `updateExempt` only — not the standard ERC20 functions.
- Minimal consumer-side interfaces for external protocols (`IDEXRouter`, `IDEXFactory`, `IRewardTracker`, `IUniversalRouter`, `IV4PositionManager`, `IWETH`, `ILiFi`, `IOFT`) stay minimal — they declare only the calls our contracts actually make. `ILiFi`/`IOFT` are decode/call-only mirrors of LiFi and LayerZero types; their struct layouts MUST stay byte-identical to the upstream sources (the LiFi Diamond is called low-level with `abi.decode` pinning).

## Foundry Conventions

### Project Structure

```
src/           # Contracts
test/          # Tests (.t.sol)
script/        # Deployment scripts (.s.sol)
lib/           # Dependencies (git submodules)
```

### Naming Conventions

**Files:** Contracts `PascalCase.sol`, Interfaces `IMyContract.sol`, Tests `MyContract.t.sol`, Scripts `Deploy.s.sol`

**Code:** Functions/variables `mixedCase`, Constants/immutables `SCREAMING_SNAKE_CASE`, Structs/enums `PascalCase`

**Tests:** Unit `test_FunctionName_Condition`, Reverts `test_RevertWhen_Condition`, Fuzz `testFuzz_FunctionName`, Invariant `invariant_PropertyName`, Fork `testFork_Scenario`

### Import Style

Use named imports only:

```solidity
import {Contract} from "src/Contract.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
```

### Testing Requirements

- Write tests for both success and revert scenarios
- Use `vm.expectRevert()` for expected failures
- Include descriptive assertion messages: `assertEq(result, expected, "error message")`
- Test state changes, event emissions, and return values
- Never place assertions in `setUp()` functions
- Use `vm.assume()` to exclude invalid fuzz inputs (not early returns)
- Use `bound()` for controlled input ranges

### Security Practices

- Follow CEI (Checks-Effects-Interactions) pattern
- Implement reentrancy protection where applicable
- Validate all inputs and external calls
- Use events for important state changes
- Consider front-running and MEV implications

### NatSpec Documentation

```solidity
/// @notice Brief description
/// @dev Implementation details
/// @param name Parameter description
/// @return Description of return value
```

### Common Commands

```bash
forge build                    # Compile
forge test                     # Run tests
forge test -vvv                # Verbose trace
forge test --match-test <pat>  # Run specific tests
forge coverage --ir-minimum --skip "*/dex/*" --skip "script/*" --report summary
forge lint                     # Lint for issues
forge script script/Deploy.s.sol --broadcast --verify
```

**DO NOT** modify `foundry.toml` without asking first.

## Review Process

After writing or modifying contracts, use these project commands:

1. `/project:audit <contract>` — Security review against architecture plan
2. `/project:integration-check` — Cross-contract consistency verification
3. `/project:write-tests <contract>` — Generate Foundry test suite

If the auditor finds a real issue, sweep the codebase for similar patterns using variant analysis.

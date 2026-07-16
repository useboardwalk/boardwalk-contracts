# Boardwalk Launchpad: Technical Spec

A permissionless token launch protocol. Each launch deploys 4–5 EIP-1167 clones from shared implementation templates; singletons are deployed once per chain. Launches feature an embedded transfer tax, time-weighted presale, permanently locked liquidity, LP staking with multiplier points, and (on Ethereum) onchain governance over protocol revenue.

The protocol token is BWLK, home chain Ethereum. It replaces BMX via a 1:1 migration; governance and the revenue hub live on Ethereum. See *BWLK token and migration*.

Supported chains: Ethereum (1), Base (8453), Arbitrum (42161), Robinhood Chain (4663). The underlying DEX is the canonical Uniswap V2 deployment on every chain, and the raise token is the chain's canonical WETH.

---

## Architecture

**Per-launch clones** (deployed by `LaunchFactory.createLaunch`):
- `BoardwalkToken`: ERC20 with embedded tax
- `FeeDistributor`: splits tax across recipients
- `PresaleManager`: contributions, seeding, claims, refunds
- `LPStaking`: staking with vesting, fee epochs, multiplier points
- `VestingStream`: linear vesting (Advanced path only when `presalePercent < 50%`)

**Singletons** (deployed once per chain):
- `LaunchFactory`, `BoardwalkLPManager`, `BoardwalkFeeCollector`, `IntegratorFeeCollector`, `BoostBurn`
- Ethereum only: `GovernanceVoter`, `LPLocker`, `ParticipationDistributor`, plus the token/migration set (`BWLK`, `BwlkMigration`, `UnsoldBurner` — see *BWLK token and migration*)

Each clone is initialised exactly once. `LPStaking` and `VestingStream` use a two-step `setInitializer` → `initialize` lock so only `PresaleManager` can initialise them at seed time; the rest use OZ `Initializable`. Express launches deploy 4 clones (no `VestingStream`); Advanced launches deploy 5 when `presalePercent < 50%`, otherwise 4.

The per-transfer tax fan-out is the central flow. Sender pays `tax`; the rest goes to the destination:

```mermaid
flowchart LR
    Sender -->|"transfer(amount)"| Token[BoardwalkToken._update]
    Token -->|"tax"| FD[FeeDistributor.onTaxReceived]
    Token -->|"amount - tax"| Recipient
    FD --> LP[LPStaking.notifyFees]
    FD --> BW[BoardwalkFeeCollector.receiveFees]
    FD --> INT[IntegratorFeeCollector.receiveFees]
    FD -. accrues .-> Issuer[Issuer recipients]
    FD -. accrues .-> Ref[Referrer]
```

The LP, boardwalk, and integrator forwards are wrapped in `try/catch` so a downstream revert never bricks the transfer. Issuer and referrer shares accrue for pull-based claims.

---

## Launch paths

|                       | EXPRESS                         | ADVANCED                                                    |
| --------------------- | ------------------------------- | ----------------------------------------------------------- |
| Presale duration      | 24h (configurable, > 0)         | 7d default (admin range 2–14d)                              |
| Presale allocation    | Fixed 50%                       | 25–50%, divisible by 5%                                     |
| Start delay           | None                            | 24h                                                         |
| Graduation threshold  | 5 WETH default (admin-tunable)  | 5 WETH default (admin-tunable)                              |
| Vesting               | Disallowed                      | Up to 5 recipients; required if `presalePercent < 50%`      |
| Referrer              | Disallowed                      | Optional; can be one of the vesting recipients              |
| Issuer fee recipients | 1                               | 1–4                                                         |

Path is frozen in `LaunchInfo`. `LaunchFactory` rejects mixed configs (e.g. Express with vesting reverts).

---

## Token allocation

Total supply is fixed at `TOTAL_SUPPLY = 10_000_000_000e18` for every launch. Splits computed by `AllocationLib.compute(TOTAL_SUPPLY, presalePercent)`:

```
presaleTokens       = TOTAL_SUPPLY * presalePercent / 10_000
liquidityTokens     = presaleTokens
vestingTotal        = TOTAL_SUPPLY - presaleTokens - liquidityTokens
lpIncentiveTokens   = vestingTotal * 20 / 100
issuerVestingTokens = vestingTotal - lpIncentiveTokens
```

Invariant: `presaleTokens + liquidityTokens + lpIncentiveTokens + issuerVestingTokens == TOTAL_SUPPLY`.

LP tokens minted at seed are sent to `0x...dEaD` (permanent liquidity).

---

## Tax mechanism

Universal tax on every non-exempt transfer. Computed in `BoardwalkToken._update`, deducted from the sender, transferred to `FeeDistributor`, then forwarded via `FeeDistributor.onTaxReceived(amount)` callback.

The DEX layer is the canonical Uniswap V2 with its standard 0.30% (30 BPS) pair fee. The token tax stacks with the pair fee on swaps. Tax goes to the protocol's five fee buckets (see *Fee distribution*); the pair fee accrues to the pool's permanently-locked liquidity (0.25% to LPs and 0.05% to the Uniswap protocol where the V2 fee switch is on — Ethereum/Base/Arbitrum as of July 2026; the full 0.30% to LPs on Robinhood, where it is off). With `baseTaxBps = 95`, a swap pays ~1.25% effective (95 BPS tax on the transfer to the pair, plus 30 BPS pair fee on the swap leg).

**Tax rate** (in BPS):
- Before seed (`liquiditySeedTime == 0`): no tax. Only `PresaleManager` can mint pre-seed.
- During anti-whale (first `antiWhaleDuration` after seed): `tax = antiWhaleTaxBps - (antiWhaleTaxBps - baseTaxBps) * elapsed / antiWhaleDuration`.
- After: `baseTaxBps`.

`baseTaxBps`, `antiWhaleTaxBps`, and `antiWhaleDuration` are set at `initialize` and frozen for the life of the token. `LaunchFactory` admins configure anti-whale per future launch via `executeSetAntiWhale(taxBps, duration)` within bounds `taxBps ∈ [500, 4000]` BPS and `duration ∈ [5 min, 90 min]`. `baseTaxBps <= antiWhaleTaxBps` is enforced so the decay formula cannot underflow. `liquiditySeedTime` is set exactly once by `PresaleManager.seedLiquidity()`; zero and future timestamps revert.

**Exemption list** (set at `initialize`):

| Address                              | Reason                                                              |
| ------------------------------------ | ------------------------------------------------------------------- |
| `FeeDistributor`                     | Receives tax; exemption prevents recursive tax on the callback path |
| `PresaleManager`                     | Mints initial supply; presale claims after cliff are tax-free       |
| `VestingStream`                      | Vesting claims are tax-free                                         |
| `LPStaking`                          | Reward distribution and fee inflows are tax-free                    |
| `BoardwalkLPManager`                 | Tax-exempt LP add/remove wrapper                                    |
| `BoardwalkFeeCollector`              | Keeper batch-swaps to raise token are tax-free                      |
| `IntegratorFeeCollector` (cond.)     | Receives integrator share via `receiveFees`; per-slot claims are tax-free |

Conditional row applies only when the chain has a non-zero `integratorBps`.

The exempt set is otherwise immutable post-init. The only rotation flow is `FeeDistributor.setFeeCollector` (boardwalk migration), which atomically rotates exemption with the role address and rejects a collector that is already exempt. The chain-level `IntegratorFeeCollector` is immutable; its exempt status cannot be re-pointed.

---

## Fee distribution

The split is frozen per launch at `FeeDistributor.initialize`. Defaults are set at `LaunchFactory` deployment and apply to future launches.

**Default fee total:** 95 BPS token tax (`baseTaxBps` = `_feeBpsDefaults.total`) plus 30 BPS on the Uniswap V2 pair (0.25% LP / 0.05% protocol) = **1.25%** effective on swaps.

**Factory storage vs launch path:** The factory stores one `FeeBpsDefaults` per chain. `boardwalk` is the **Express** Boardwalk rate; `referrer` (5 BPS) is carved from boardwalk on **Advanced** launches when a referrer address is set (`boardwalkEffective = boardwalk - referrer`). Express forbids a referrer (`ReferrerNotAllowedOnExpressPath`). Advanced without a referrer keeps the full boardwalk bucket (the referrer slice defaults to Boardwalk).

| Bucket | Source field | Tunable post-deploy | Bound | Routing |
| ------ | ------------ | ------------------- | ----- | ------- |
| Issuer | `_feeBpsDefaults.issuer` | yes (`executeSetFeeDefaults`) | 10–80 BPS | Accrues per recipient; claim as raise token via `claimAsRaiseToken` (10%/24h rate limit) |
| Boardwalk | `_feeBpsDefaults.boardwalk` | yes | 10–50 BPS | Forwarded to `BoardwalkFeeCollector.receiveFees` (try/catch + `pendingBoardwalkFees` retry) |
| LP staking | `_feeBpsDefaults.incentive` | yes | ≤ 50 BPS | Forwarded to `LPStaking.notifyFees` (try/catch + `pendingLpFees` retry) |
| Referrer | `_feeBpsDefaults.referrer` | yes | ≤ 10 BPS, ≤ boardwalk | Optional Advanced-only role. Carved from boardwalk when set; otherwise the slot stays in boardwalk. Claims in the launch token via `claimReferrerFees` |
| Integrator | `INTEGRATOR_BPS` | **no** (immutable on factory) | ≤ 50 BPS | Single bucket forwarded to chain-level `IntegratorFeeCollector.receiveFees` (try/catch + `pendingIntegratorFees` retry); collector splits internally per frozen `integratorSplits[]` |
| **Total** | `_feeBpsDefaults.total` | n/a | n/a | Validated to equal `issuer + boardwalk + incentive + INTEGRATOR_BPS` |

`_validateFeeDefaults` enforces bounds and the `total` invariant on every `executeSetFeeDefaults`. `INTEGRATOR_BPS` can never be tuned post-deployment; changing it requires a new factory.

Referrer carve-out: when a referrer is set, `boardwalkEffective = boardwalk - referrer`. Total tax stays at the configured BPS regardless. Integrator and referrer can coexist on Advanced launches.

### Default fee schedule (BPS)

One standardized schedule applies on every supported chain. Factory parameters (`issuer + boardwalk + incentive + INTEGRATOR_BPS` = `total` = 95; `referrer` not in `total`):

| Chain | `issuer` | `boardwalk` | `referrer` | `incentive` | `integrators` |
| ----- | -------- | ----------- | ---------- | ----------- | ------------- |
| Ethereum, Base, Arbitrum, Robinhood | 35 | 35 | 5 | 15 | 10 |

The integrator bucket is five equal 2-BPS slots: Sherlock, DefiLlama Research, 0x, Security Alliance (SEAL), and DeFi Llama (the last two are public-goods donations). Recipient addresses and splits are frozen at `IntegratorFeeCollector` construction ([script/FeeSchedules.sol](script/FeeSchedules.sol)).

**Effective splits at launch** (add the 0.30% Uniswap V2 pair fee on swaps for the 1.25% total):

| Path | All chains |
| ---- | ---------- |
| **Advanced** (referrer set) | 0.35% issuer, 0.30% Boardwalk, 0.05% referrer, 0.15% LP incentives, 0.10% integrators |
| **Express** (no referrer) | 0.35% issuer, 0.35% Boardwalk, 0.15% LP incentives, 0.10% integrators |

`INTEGRATOR_BPS` is immutable in the factory; changing it requires a new factory deployment. Other buckets can be updated via timelocked `executeSetFeeDefaults` for **future** launches only.

**Per-transfer routing in `onTaxReceived`:**

1. Compute `lp / boardwalk / issuer / referrer / integrator` shares (proportional by frozen BPS).
2. `try LPStaking.notifyFees(lpShare)`; on revert, `pendingLpFees += lpShare`, emit `FeeForwardFailed`.
3. `try FeeCollector.receiveFees(token, boardwalkShare)`; on revert, `pendingBoardwalkFees += boardwalkShare`.
4. `try IntegratorFeeCollector.receiveFees(token, integratorShare)`; on revert, `pendingIntegratorFees += integratorShare`. The collector is protocol-deployed and immutable; `FeeDistributor` grants it max allowance at init for the pull pattern.
5. Distribute issuer share across recipients by frozen splits; last recipient absorbs rounding dust.
6. Increment `referrerAccrued`.

`retryPendingFees()` is permissionless and flushes any of the three pending buckets. Steps 1–6 never revert in aggregate, so a downstream contract cannot brick transfers.

**Issuer claim** (`claimAsRaiseToken(recipientIdx, minRaiseTokenOut, deadline)`): rate-limited to 10% of live unclaimed (`totalAccrued - totalClaimed`) per recipient per 24h, swapped via the standard router. The cap is anchored to live unclaimed rather than lifetime cumulative, so it cannot inflate from history. Under steady inflow `f`/day the equilibrium is `claim ≈ f` with a rolling backlog of `~9f`. Burst drains under no further inflow decay geometrically `(9/10)^k`. Dust escape: when 10% of unclaimed rounds to zero, the full unclaimed amount is claimable in one call.

**Integrator claim** (on `IntegratorFeeCollector`):

- Allocation: `receiveFees(token, amount)` pulls the bucket and splits it across slots by frozen `integratorSplits[]`; per-slot per-token state in `claimStates[slot][token]`.
- Modes: `claim(token, minOut, deadline)` for one token; `claimBatch(tokens[], minAmountsOut[], deadline)` for many.
- Rate limit: 25% of live unclaimed (`totalAccrued - totalClaimed`) per (slot, token) per 24h, anchored to live state so the cap cannot inflate from cumulative deposits. Under steady inflow `f`/day the equilibrium is `claim ≈ f` with a rolling backlog of `~3f`. Burst drains under no further inflow decay geometrically `(3/4)^k`. Dust escape: when 25% of unclaimed rounds to zero, the full unclaimed amount is claimable in one call. State updates only on successful swap, so a failed claim does not consume the window.
- Batch isolation: each per-token attempt wrapped in `try this._claimOneToken(...) catch { emit ClaimFailed(...) }`; tokens with nothing claimable are skipped silently.
- Off-chain helpers: `quote(integrator, token, slippageBps)` and `quoteBatch(integrator, tokens[], slippageBps)` compute `minAmountsOut[]` from `IDEXRouter.getAmountsOut` for caller convenience.

**Per-recipient address changes** (delays in admin table):

- Issuer / referrer rotations on `FeeDistributor`: only the current recipient can signal and cancel; anyone can execute after the delay. Claims keep flowing to the OLD address until execute lands.
- Integrator slot rotations on `IntegratorFeeCollector`: only the current slot address can signal and cancel; anyone can `executeChangeAddress(slotIdx, newAddress)` after the delay. Execute rejects `address(0)` and any address already held by another slot. Storage is slot-keyed; rotation only flips the `address ↔ slot` reverse map.
- Fee collector rotation on `FeeDistributor.setFeeCollector` (called by the current `feeCollector` only): atomically swaps token exemption and approvals; reverts if the new collector is already exempt. The 7-day delay lives at the singleton level on `BoardwalkFeeCollector.MIGRATE_COLLECTOR`.

`FeeDistributor` and `IntegratorFeeCollector` both block the generic `signalAction` path (`_authAdmin` reverts); only the typed flows above mutate state.

---

## Presale

**Lifecycle** (`PresaleManager`):

1. `contribute(amount)` during `[presaleStart, presaleEnd]`. Each contribution gets a time-decayed bonus multiplier `bonus = 11_000 → 10_000` over the window (10% bonus at start, 0% at end). `weightedAmount = amount * bonus / 10_000`. Per-user `contributions[user]` tracks `totalContributed` and `weightedContributed`; global `totalRaised` and `totalWeightedRaise` aggregate.
2. After `presaleEnd + 1h` (`SEED_DELAY`), `seedLiquidity()` is permissionless. If `totalRaised >= graduationThreshold`:
   - `AllocationLib.compute()` → mints to `PresaleManager` (presale + liquidity), `LPStaking` (incentive), `VestingStream` (issuer vesting if applicable).
   - Transfers token + raise token directly to the pair, calls `pair.mint(DEAD_ADDRESS)`. LP tokens are unrecoverable.
   - Initialises `LPStaking` and (if applicable) `VestingStream` with `seedTime`.
   - Calls `token.setLiquiditySeedTime(seedTime)`; anti-whale tax begins counting down.
3. After `seedTime + 7d cliff`, `claimTokens()` pays out `userTokenAmount = user.weightedContributed * presaleTokens / totalWeightedRaise` (O(1)).
4. If presale fails (under threshold by `seedLiquidity()` time), `refund()` returns each user's `totalContributed`.

`setVestingConfig(recipients[], amounts[])` is called by `LaunchFactory` exactly once for Advanced launches. Only `PresaleManager` can call `token.mint(...)`, and total minted is bounded by `TOTAL_SUPPLY`.

The graduation threshold defaults to 5 WETH on both paths (deploy-time `GRADUATION_EXPRESS` / `GRADUATION_ADVANCED`, tunable per path via the timelocked `executeSetGraduation` for future launches).

---

## LP staking

`LPStaking` has zero admin functions; fully immutable after `initialize`. Two reward streams flow into a single weight-based accumulator:

**Vesting reward** (continuous, 3-year linear from `vestingStart = seedTime + 24h` to `vestingStart + 3 years`):

```
baseVestingRate = vestingAllocation / VESTING_DURATION   // tokens per second
vestingDelta    = elapsed * baseVestingRate
```

**Fee reward** (weekly epochs, anchored to trigger time):

```
feeRewardRate = currentEpochFees / 7 days
feeDelta      = elapsed * feeRewardRate
```

Epoch advancement happens lazily inside `_updateAllRewards()`, called by every `stake / withdraw / claim / notifyFees`. When `block.timestamp >= currentEpochStart + 7 days`:

- `currentEpochFees ← pendingEpochFees`, `pendingEpochFees ← 0`
- `feeRewardRate = currentEpochFees / 7 days`
- `currentEpochStart ← block.timestamp` (anchored to trigger, not boundary, so every epoch gets a full 7-day window even when the keeper is late)

**Cross-epoch fee attribution**: Fees accumulated during epoch N (in `pendingEpochFees`) are streamed during epoch N+1, not the accrual epoch. On rollover the bucket is promoted to `currentEpochFees` and streamed pro-rata against the live `totalWeight` over the following 7 days. A staker who provides weight at any point during epoch N+1, including the block that triggers the rollover, shares pro-rata in fees that accrued during epoch N. This is intentional smoothing: stakers must remain staked through the streaming window of epoch N+1 to capture the full epoch-N bucket.

`notifyFees` is the most reliable trigger because it fires on every taxed transfer. Both endpoints (`FeeDistributor` and `LPStaking`) are tax-exempt, so `BoardwalkToken._update` short-circuits before any callback can re-enter, and `nonReentrant` is omitted on this path. The caller wraps the call in `try/catch`.

**Accumulator math** (1e30 precision):

```
accRewardPerWeight += (vestingDelta + feeDelta) * 1e30 / totalWeight
pending(user)       = user.weight * accRewardPerWeight / 1e30 - user.rewardDebt
```

**Multiplier points** accrue at a fixed rate of `1 MP per LP per year`:

```
newMp        = user.lpStaked * elapsed / 365 days   // since user.lastMpUpdate
user.weight  = user.lpStaked + user.multiplierPoints
mpToBurn     = user.multiplierPoints * withdrawAmt / user.lpStaked   // proportional burn on withdraw
```

MP is lazily crystallised on user interactions; active users accrue MP sooner than inactive ones.

- **Pending reward ordering**: pending rewards are settled with the OLD weight before MP is updated, so an MP delta cannot inflate already-earned rewards.
- **Zero-staker fee notifications**: when `totalWeight == 0`, the inbound amount is **burned to `DEAD_ADDRESS`** and `FeesLost(amount)` is emitted. This prevents a first staker after dormancy from harvesting fees that arrived while there were no stakers. The FD-side `try` still succeeds, so `pendingLpFees` is NOT incremented in this path.
- **Zero-staker accrual intervals**: vesting and fee accrual during zero-staker windows is permanently lost; `lastRewardUpdate` advances without distribution to prevent unbounded carryover.

---

## Vesting

`VestingStream` is per-launch (Advanced only), supports up to 5 recipients, and is immutable after `initialize` except for recipient address changes.

```
cliffEnd     = seedTime + 7 days
vestingEnd   = cliffEnd  + 3 years
claimable(i) = (block.timestamp - cliffEnd) * allocations[i].amount / 3 years - allocations[i].claimed
```

Claims revert before `cliffEnd`. Vesting amounts, schedule, and labels are immutable; only recipient addresses can change.

**Recipient changes** are issuer-controlled. The issuer signals via the generic `Timelocked.signalAction(action, dataHash)` (gated by `_authAdmin == issuer`); after the 7-day delay, anyone can call typed `executeChangeRecipientAddress(allocationId, newAddress)`. Execute auto-claims any vested-but-unclaimed tokens for the **outgoing** recipient before switching. Per-allocation `signalBurnAction / executeBurnAction` makes a recipient address permanently immutable.

`VestingStream` is in the token's exempt list, so vesting claims do not pay tax.

---

## Cross-contract flows

### 1. Launch creation (`LaunchFactory.createLaunch`)

1. Validate config (path, presale percent divisibility, vesting required when `presalePercent < 50%`, splits sum, address bounds, distinct-address invariant against immutable exempt singletons).
2. Burn `_effectiveCost(bwlkBurnAmount, memberLaunchDiscountBps, issuer)` BWLK from issuer to dead.
3. Deploy clones (token, feeDistributor, presale, lpStaking; vesting if Advanced + needs vesting).
4. Lock `LPStaking.initAuthorizer = presale`. Lock `VestingStream.initAuthorizer = presale, issuer = issuer`.
5. Initialise token (name, ticker, baseTaxBps, antiWhaleTaxBps, antiWhaleDuration, feeDistributor, presale, exempt addresses including `INTEGRATOR_COLLECTOR` when `integratorBps > 0`).
6. Initialise feeDistributor (token, lpStaking, feeCollector, integratorCollector, router, raiseToken, issuerRecipients[], issuerSplits[], referrer, all five bucket BPS).
7. Initialise presale (all clone addresses, raiseToken, duration, presalePercent, graduationThreshold, startDelay flag).
8. If Advanced + needs vesting: call `presale.setVestingConfig(recipients, amounts)`.
9. Store `LaunchInfo`, emit `LaunchCreated` (with labels for indexers).

### 2. Presale → seed → claim

1. Users `contribute(amount)` during the window. `weightedContributed` is computed with the live time-decay multiplier and added to per-user and global totals.
2. After `presaleEnd + 1h`, anyone calls `seedLiquidity()`. Mints all four buckets, transfers token + raise token to the Uniswap V2 pair, calls `pair.mint(DEAD_ADDRESS)`, initialises LPStaking and (if applicable) VestingStream, sets `liquiditySeedTime`.
3. After `seedTime + 7 days`, contributors call `claimTokens()`.
4. If under threshold at `seedLiquidity()` time, `refund()` returns `totalContributed`.

### 3. Transfer → tax → distribution

1. Non-exempt sender transfers; `BoardwalkToken._update` checks both endpoints against `isExempt`.
2. Tax computed (anti-whale or base), debited from amount, transferred to FeeDistributor.
3. `FeeDistributor.onTaxReceived(tax)`: split into `lp / boardwalk / issuer / referrer / integrator` shares; `try`-forward `lp`, `boardwalk`, and `integrator` (each wrapped in `try/catch` with a per-bucket `pending*Fees` retry queue); accrue `issuer` and `referrer` shares.
4. **LP path**: `LPStaking.notifyFees(lp)` advances rewards. If `totalWeight > 0`, the amount lands in `pendingEpochFees`. If `totalWeight == 0`, the amount is burned to `DEAD_ADDRESS` and `FeesLost(lp)` is emitted, so a first staker after dormancy cannot harvest fees that arrived earlier.
5. **Boardwalk path**: `FeeCollector.receiveFees(token, share)` → `accumulatedFees[token] += share`.
6. **Integrator path**: `IntegratorFeeCollector.receiveFees(token, share)` pulls via `safeTransferFrom`, allocates across slots by frozen splits, and marks the token tracked per slot. Each integrator independently calls `claim` / `claimBatch` to swap their accrued share to the raise token.

### 4. Stake / withdraw / claim

- **Stake**: `_updateAllRewards()` → settle pending with OLD weight → `_updateUserMp(user)` → pull LP → update `lpStaked`, `totalWeight`, `rewardDebt`.
- **Withdraw**: same prefix → compute `mpToBurn = mp * amount / lpStaked` → decrement `lpStaked`, `multiplierPoints`, `totalWeight` → set new `rewardDebt` → push LP.
- **Claim**: `_updateAllRewards()` → compute pending with STORED weight → push reward token → `_updateUserMp(user)` → recalc debt.

### 5. Keeper batch swap (`BoardwalkFeeCollector`)

1. Keeper calls `swapToRaiseToken(tokens[], minAmountsOut[], deadline)`. For bridge-only revenue with no swaps to perform, the keeper calls `forwardRevenue()` instead (no-op on zero balance).
2. For each token: read balance, lazy `forceApprove(router, max)` if undersized allowance, swap, clear `accumulatedFees[token]`. `RAISE_TOKEN` entries are silently skipped (passing them to the router would revert with `[X, X]`).
3. Forward the collector's full raise-token balance (swap output PLUS any pre-existing balance such as bridged revenue or residual) to `treasury` (or split 10/90 with `GovernanceVoter` on Ethereum).

### 6. Governance vote → finalize → execute (Ethereum)

See *Governance* below.

---

## Cross-chain membership (NFT bridge)

The Boardwalk Club collection (SeaDrop on Base, immutable, 224 fixed supply, ids 1–224) bridges to
the other deployment chains over Chainlink CCIP, hub-and-spoke with Base as the hub:

- **Base**: `BoardwalkClubLockbox` escrows originals (`locked[id]` accounting set before the pull)
  and sends a 64-byte `(recipient, tokenId)` message to the destination mirror; inbound messages
  from the registered peer release escrow. Release requires `locked[id]` — a peer can only release
  what `bridge` escrowed. The original collection is never modified.
- **Spokes** (Ethereum, Arbitrum, Robinhood): `BoardwalkClubMirror` — a standard transferable
  ERC721 reproducing the original's name, symbol, ids, and URIs — mints on inbound messages and
  burns to bridge back. Its only peer is the Base lockbox, pinned at the type level
  (`OnlyBaseSelector`); spoke→spoke moves are two hops via Base (Robinhood's only CCIP
  counterparties are Ethereum and Base, so a spoke mesh is not possible anyway). Each spoke's
  `nftCollection` points at its mirror via the existing `SET_NFT_COLLECTION` timelocks; the
  deprecated soulbound `BoardwalkClub` airdrop contract stays deployed but no longer gates.
- **New spokes**: the lockbox's one-shot `initializePeers` is consumed, so a new spoke mirror
  (e.g. Robinhood) is wired via the typed `SET_PEER` timelock —
  [script/05_AddLockboxPeer.s.sol](script/05_AddLockboxPeer.s.sol): signal, 7-day delay, execute,
  then a canary round-trip before announcement.
- **Invariant**: per token id, exactly one live representation exists — the original with a
  holder, or (while `locked`) exactly one spoke mirror.
- **Fees**: `bridge(destinationChainSelector, tokenId, recipient)` is `payable` (documented
  carve-out from the no-payable rule). The caller pays the CCIP fee in native, quoted via
  `quoteBridge`; exactly the quoted fee is forwarded to the router and any excess is refunded
  last. Bridging is owner-only on both sides (approvals are not honored).
- **Failure handling**: a reverting delivery parks in CCIP's failed state and is permissionlessly
  re-executable with more gas; a delivery to a peer with no code (or one failing the ERC165
  check) is a **vacuous SUCCESS** — never retryable — which is why wiring is timelocked,
  every lane gets a canary round-trip before launch, and the lockbox carries a 30-day
  `FORCE_UNLOCK` backstop (the sole path that releases a `locked` original). The rightful
  recipient of a stuck original is not knowable on Base (the spoke representation may have
  changed hands in a secondary sale), so `FORCE_UNLOCK` takes an explicit recipient, verified
  off-chain as the current spoke holder and committed at signal time; the 30-day public
  `ChangeSignaled` window is the adjudication mechanism, and while a lane is alive the holder of
  a live representation defeats a wrongful signal outright by bridging back (release cancels the
  pending signal). Signaling requires the token to be escrowed, and force-unlock must only be
  used on a CCIP-SUCCESS (vacuous) message or a deprecated lane — never on a FAILED message,
  which is recoverable by manual re-execution (force-unlocking it double-mints when the message
  is later replayed). Lane changes must drain in-flight messages first: `removePeer` on the
  outgoing side, wait out deliveries, then execute.

---

## Cross-chain revenue bridging

Protocol revenue accrues on each source chain in that chain's raise token (WETH everywhere),
aggregated by that chain's `BoardwalkFeeCollector`. Weekly, an automated keeper consolidates it to
Ethereum, landing as **WETH** in the Ethereum `BoardwalkFeeCollector` (where the 10/90
treasury/governance split applies). Revenue flows only through onchain bridging contracts the
keeper triggers.

Two contracts (`src/crosschain/`):

- **`RevenueBridger`** (every source lane: Base, Arbitrum, Robinhood): generic. Holds the raise
  token (it is the source FeeCollector `treasury`). The bridge keeper calls
  `bridgeToEthereum(amount, lifiCalldata)`, forwarding keeper-built LiFi route calldata to the
  per-chain LiFi Diamond. Every lane uses a pure Across V4 WETH route (`msg.value == 0`). The
  contract retains support for composed (source-swap) lanes and native route fees — payable
  `bridgeToEthereum` with keeper `msg.value`, excess refunded, and an unconditional `receive()`
  for the Diamond's excess-fee refund — for future non-WETH raise tokens; no current lane uses
  either.
- **`EthereumRevenueSwapper`** (hub): delivery target for all lanes (rescue-capable, so a wrong
  asset is recoverable — at the rescue-less FeeCollector it would be stuck). Swaps a delivered
  non-WETH `tokenIn` → WETH via the 0x AllowanceHolder (`swapAndForward`), then forwards its
  entire WETH balance to the Ethereum FeeCollector — bridged-in WETH rides along. Permissionless
  `forwardWeth()` is the standard sweep for the all-WETH lane set.

Per-chain config (LiFi Diamond, facet selector, lane WETH, AllowanceHolder) lives in
[script/CrossChainConfig.sol](script/CrossChainConfig.sol); deploy via
[script/06_DeployRevenueBridging.s.sol](script/06_DeployRevenueBridging.s.sol). Deploy order: the
Ethereum swapper first, then each source lane pinned to it as `ETHEREUM_DESTINATION`.

### Security controls (`RevenueBridger`)

`bridgeToEthereum` is bridge-keeper-gated, `nonReentrant`, payable:

1. **Diamond + selector allowlist**: the call target is the immutable Diamond; `bytes4(lifiCalldata)`
   must be allowlisted (timelocked `SET_SELECTOR`). One shape per lane, matching `HAS_SOURCE_SWAPS`:
   pure Across V4 (`0xa1f1ce43`) on Base, Arbitrum, and Robinhood.
2. **Calldata pinning**: `abi.decode(lifiCalldata[4:], (ILiFi.BridgeData))` (mirrors LiFi's own
   `CalldataVerificationFacet`) pins `receiver == EthereumRevenueSwapper`, `destinationChainId == 1`,
   `hasDestinationCall == false`, and `hasSourceSwaps == HAS_SOURCE_SWAPS` (so a mis-curated
   wrong-shape selector self-reverts). On pure Across V4 lanes it also decodes `AcrossV4Data` and pins
   `refundAddress == address(this)` (load-bearing — closes the forced-expiry self-refund path that
   would otherwise reclaim the full input on origin), `sendingAssetId == raise token`,
   `receivingAssetId == Ethereum WETH`, `outputAmount >= amount * (10000 - MAX_FEE_BPS) / 10000`, and
   `receiverAddress == swapper`. On composed lanes (retained shape; no current lane) it pins only the
   deposited input across `requiresDeposit` swap legs (`sendingAssetId == raise token`, summed
   `fromAmount == amount`) and never the post-swap `BridgeData.sendingAssetId`/`minAmount`.
3. **Exact-approve + reset + balance-delta**: approves the Diamond for exactly `amount`, calls, resets
   to 0, asserts the carrier balance dropped by at most `amount`.

### Trust statement (per lane)

- **Base / Arbitrum / Robinhood**: delivery (recipient + output asset + origin refund) is **pinned
  onchain** (Across V4 facet-data). Residual = the bounded relayer-fee spread (`MAX_FEE_BPS`) plus
  LiFi-Diamond upgrade risk against the standing balance.
- **Ethereum swap leg** (`EthereumRevenueSwapper.swapAndForward`): keeper-supplied `tokenIn` + 0x
  calldata + `minOut`; the keeper `minOut` is the bound. `tokenIn` is pinned `!= WETH` so keeper
  calldata can never pull the contract's bridged WETH, and the output is always WETH to the
  immutable `FEE_COLLECTOR`.

Emergency response = `revokeKeeper` + halt the accrual cron (both instant); keeper replacement is then a 7-day timelock.

### Invariants

- **Source `governanceVault == address(0)` forever** (Base, Arbitrum, Robinhood): a set vault
  diverts 90% of `forwardRevenue` to the vault, silently bypassing the bridger. Never call
  `executeSetGovernanceVault` there; alert on `GovernanceVaultUpdated`. Ethereum is the governance
  home: its FeeCollector's `governanceVault` is set to the BWLK `GovernanceVoter` (existing 7d
  timelock; the one legitimate `GovernanceVaultUpdated`), and Ethereum has no bridging lane — the
  lane config reverts for chainId 1.
- **Nothing but WETH addressed to the Ethereum FeeCollector**: it can only swap launch-listed
  tokens and has no rescue. Made structural — all lanes deliver to the rescue-capable swapper; only
  its WETH (`swapAndForward`'s full-balance forward / `forwardWeth`) ever reaches the FeeCollector.

---

## BWLK token and migration

BMX migrates 1:1 to BWLK; Ethereum mainnet is the protocol's governance and revenue home. Three contracts in `src/token/`, all Ethereum-only.

**BWLK** ([src/token/BWLK.sol](src/token/BWLK.sol)): fixed-supply ERC20, `3_150_000e18` minted once at deployment. No minter, owner, or pause. Cross-chain via Chainlink CCT with a LockReleaseTokenPool on Ethereum (BurnMint representations on the other chains, used for launch burns and Boost/Deboost activity), so the token itself never mints or burns; `getCCIPAdmin()` exists only for `TokenAdminRegistry` registration. Supply split: 2,711,068 migration pool (86.07%), 157,500 CCA auction (5%), 157,500 LP seed (5%), 123,932 LP incentives escrow (3.93%, 1-year program).

**Migration** ([src/token/BwlkMigration.sol](src/token/BwlkMigration.sol)): one-way, permissionless, once per source address, all-or-nothing. `migrate(destination, snapshotBmx, snapshotPoints, proof)` reads the caller's entire BMX balance (the legacy token surrendered on Ethereum), sends it to dead, and stakes an equal amount of BWLK for `destination` through the three reward trackers (mirroring the staking router's tier flow). Every migrator earns a voter-point credit of 16% of the migrated amount, minted as bnBWLK into the fee tracker. A merkle leaf exists only to carry a prior Base staker's points, scaled by how much of the staked position they bring back:

```
points = brought * 16%
       + snapshotPoints * 116% * min(brought, snapshotBmx) / snapshotBmx   // stakers only
```

The root is one-shot (`setMerkleRoot`); post-publication corrections go through owner-only `creditPoints`, which can add points but has no path to BWLK. `migrate` reverts while the voter is finalizing an epoch, and after `CLAIM_DEADLINE`; past the deadline the owner sweeps the unclaimed pool. The migrator can never over-distribute — payouts are 1:1 against a fixed pre-funded pool, and an underfunded pool makes `migrate` revert rather than short-pay. The snapshot is built by the pipeline in [snapshot/](snapshot/) (stakers-only leaves; exclusions are an explicit allowlist — no bytecode check, contract-held stakes migrate too; validated against the trackers' `totalDepositSupply` before publishing).

**Launch** ([src/token/UnsoldBurner.sol](src/token/UnsoldBurner.sol) + [script/bwlk/06_LaunchBwlkCca.s.sol](script/bwlk/06_LaunchBwlkCca.s.sol)): the 315,000 market-formation bucket (157,500 auction + 157,500 LP seed) launches through Uniswap's LiquidityLauncher + LBPStrategy (continuous clearing auction, native ETH raise) — never the raw CCA factory, whose auctions the strategy cannot sweep. This launch has no graduation threshold (`isGraduated()` is true from creation, attested at launch). `UnsoldBurner` is the auction's `tokensRecipient`: no admin, and BWLK can only ever leave to dead. Anyone calls `sweep(auction)` once the auction ends. The LP positions mint to `LPLocker`; the registrar registers each one (`registerPosition`, full pool key pinned to the voter's) and renounces. The pool's hook is only knowable post-launch, so `GovernanceVoter.POOL_HOOKS` is one-shot settable via owner-only `setPoolHooks` (open only when deployed unset), and `execute()` blocks options 2/3/4 until it is committed.

Deploy scripts live in [script/bwlk/](script/bwlk/): `01` token, `02` governance, `03` migrator (root before funding — a funded migrator locks the pool until `CLAIM_DEADLINE`), `05` burner, `06` the CCA launch itself (sanity-checks the wiring, then funds via Permit2 and batches the launcher's `depositToken` + `distributeToken` in one `multicall`; prints and verifies the CREATE2-predicted auction address). `04_AssertBwlkDeploy.s.sol` is the go-live gate: `assertAll` reverts unless the whole wiring holds — pool funded and root set, tracker handler/minter/distributor/private-mode wiring, staking gov custody, claim-window plausibility, and the post-launch one-shots (hook committed, registrar renounced, burner and locker bound to the real auction and voter).

---

## Contract reference

| Contract | Type | Source | Auth model |
| -------- | ---- | ------ | ---------- |
| `BoardwalkToken` | clone | [src/core/BoardwalkToken.sol](src/core/BoardwalkToken.sol) | No owner; `feeDistributor` may rotate own exempt flag |
| `FeeDistributor` | clone | [src/core/FeeDistributor.sol](src/core/FeeDistributor.sol) | `Timelocked`; generic admin disabled; only the current issuer / referrer can rotate their own slot |
| `PresaleManager` | clone | [src/core/PresaleManager.sol](src/core/PresaleManager.sol) | No admin; `setVestingConfig` is one-shot factory-only |
| `LPStaking` | clone | [src/core/LPStaking.sol](src/core/LPStaking.sol) | No admin; two-step initializer lock |
| `VestingStream` | clone | [src/core/VestingStream.sol](src/core/VestingStream.sol) | `Timelocked`; `_authAdmin == issuer`; two-step initializer lock |
| `LaunchFactory` | singleton | [src/core/LaunchFactory.sol](src/core/LaunchFactory.sol) | `Ownable2Step + Timelocked + MembershipDiscount`; owner-controlled |
| `BoardwalkLPManager` | singleton | [src/core/BoardwalkLPManager.sol](src/core/BoardwalkLPManager.sol) | No admin; immutable; restricted to pairs containing `RAISE_TOKEN` |
| `BoardwalkFeeCollector` | singleton | [src/core/BoardwalkFeeCollector.sol](src/core/BoardwalkFeeCollector.sol) | `Ownable2Step + Timelocked` |
| `IntegratorFeeCollector` | singleton (per chain) | [src/core/IntegratorFeeCollector.sol](src/core/IntegratorFeeCollector.sol) | `Ownable2Step + Timelocked`; the only `onlyOwner` function is one-shot `setFactory`; each slot rotates its own address |
| `BoostBurn` | singleton | [src/core/BoostBurn.sol](src/core/BoostBurn.sol) | `Ownable2Step + Timelocked + MembershipDiscount` |
| `BWLK` (Ethereum) | singleton | [src/token/BWLK.sol](src/token/BWLK.sol) | No owner, minter, or pause; fixed supply |
| `BwlkMigration` (Ethereum) | singleton | [src/token/BwlkMigration.sol](src/token/BwlkMigration.sol) | `Ownable2Step` (owner = 21-day governance timelock); one-shot `setMerkleRoot`; not `Timelocked` |
| `UnsoldBurner` (Ethereum) | singleton | [src/token/UnsoldBurner.sol](src/token/UnsoldBurner.sol) | No admin; BWLK can only move to dead |
| `BoardwalkClubLockbox` (Base) | singleton | [src/nft/BoardwalkClubLockbox.sol](src/nft/BoardwalkClubLockbox.sol) | `Ownable2Step + Timelocked`; generic admin + burn disabled; one-shot `initializePeers`; instant `removePeer` kill switch |
| `BoardwalkClubMirror` (spokes) | singleton (per spoke) | [src/nft/BoardwalkClubMirror.sol](src/nft/BoardwalkClubMirror.sol) | `Ownable2Step + Timelocked`; peer pinned to the Base selector; instant `removePeer` kill switch |
| `BoardwalkClubBridgeBase` | base | [src/nft/BoardwalkClubBridgeBase.sol](src/nft/BoardwalkClubBridgeBase.sol) | CCIP peer registry + send/receive plumbing; typed timelocked `SET_PEER` |
| `RevenueBridger` | singleton (every source lane) | [src/crosschain/RevenueBridger.sol](src/crosschain/RevenueBridger.sol) | `Ownable2Step + Timelocked + ReentrancyGuardTransient`; generic admin + burn disabled; typed `SET_KEEPER` / `SET_SELECTOR` / `RESCUE` (ERC20 or native); payable carve-out (native LiFi route fee via `msg.value`, excess refunded; unconditional `receive()`); instant `revokeKeeper` kill switch |
| `EthereumRevenueSwapper` | singleton (Ethereum) | [src/crosschain/EthereumRevenueSwapper.sol](src/crosschain/EthereumRevenueSwapper.sol) | as `RevenueBridger` (non-payable); typed `SET_KEEPER` / `RESCUE` (ERC20 or native); permissionless `nonReentrant` `forwardWeth`; `tokenIn != WETH` swap guard |
| `Timelocked` | base | [src/base/Timelocked.sol](src/base/Timelocked.sol) | Generic signal/execute/burn pattern; per-action delay via `_actionDelay` virtual hook |
| `MembershipDiscount` | base | [src/base/MembershipDiscount.sol](src/base/MembershipDiscount.sol) | NFT membership check + BPS discount helpers |
| `GovernanceVoter` (Ethereum) | singleton | [src/governance/GovernanceVoter.sol](src/governance/GovernanceVoter.sol) | `Ownable2Step + Timelocked`; keeper-or-owner for finalize/execute; one-shot owner `setPoolHooks` |
| `LPLocker` (Ethereum) | singleton | [src/governance/LPLocker.sol](src/governance/LPLocker.sol) | `lockPosition` only callable by `GovernanceVoter`; renounceable launch registrar for `registerPosition`; no `onERC721Received` |
| `ParticipationDistributor` (Ethereum) | singleton | [src/governance/ParticipationDistributor.sol](src/governance/ParticipationDistributor.sol) | `createStream` only callable by `GovernanceVoter` |

---

## Admin and timelocks

All admin actions go through `Timelocked.signalAction(action, dataHash) → typed execute*(...)` after the delay (7 days default, 21 days for governance-sensitive actions; 7-day expiry window). Owners can `cancelAction` any time before execute; anyone can execute once delayed. Any owner-controlled action can be permanently burned via `signalBurnAction / executeBurnAction`.

| Contract | Action | Delay | Constraints |
| -------- | ------ | ----- | ----------- |
| LaunchFactory | `SET_BWLK_BURN` | 7d | ≤ 200e18 (the launch cost, burned in BWLK); burnable |
| LaunchFactory | `SET_GRADUATION_EXPRESS / _ADVANCED` | 7d | > 0 |
| LaunchFactory | `SET_EXPRESS_DURATION` | 7d | > 0 |
| LaunchFactory | `SET_ADVANCED_DURATION` | 7d | 2–14 days |
| LaunchFactory | `SET_FEE_DEFAULTS` | 7d | issuer 10–80, boardwalk 10–50, incentive ≤ 50, referrer ≤ 10 and ≤ boardwalk; tunes the four mutable buckets only; `INTEGRATOR_BPS` is immutable; new `total` MUST equal `issuer + boardwalk + incentive + INTEGRATOR_BPS`; future launches only |
| LaunchFactory | `SET_ANTI_WHALE` | 7d | tax 500–4000 BPS, duration 5–90 min; future launches only |
| LaunchFactory | `SET_PRESALE_RANGE` | 7d | 500–5000 BPS, divisible by 500 |
| LaunchFactory | `SET_FEE_COLLECTOR` | 7d | non-zero, distinct from `INTEGRATOR_COLLECTOR` and `BOARDWALK_LP_MANAGER`; future launches only |
| LaunchFactory | `SET_NFT_COLLECTION` | 7d | `address(0)` disables discounts |
| LaunchFactory | `SET_MEMBER_LAUNCH_DISCOUNT` | 7d | ≤ 10000 BPS |
| BoardwalkFeeCollector | `SET_TREASURY / _KEEPER` | 7d | non-zero |
| BoardwalkFeeCollector | `SET_GOVERNANCE_VAULT` | 7d | may be zero (disables governance split); on non-zero, enforces `IGovernanceVoter(vault).WETH() == RAISE_TOKEN` |
| BoardwalkFeeCollector | `MIGRATE_COLLECTOR` | 7d | non-zero `newCollector`; both args committed in hash |
| BoostBurn | `SET_BWLK_COST` | 7d | 0–1 BWLK |
| BoostBurn | `SET_NFT_COLLECTION / _MEMBER_BOOST_DISCOUNT` | 7d | as LaunchFactory analogues |
| FeeDistributor | `CHANGE_ISSUER(idx) / CHANGE_REFERRER` | 7d | per-recipient self-signal; non-zero in execute; not burnable |
| IntegratorFeeCollector | `CHANGE_ADDRESS(slotIdx)` | **14d** | per-slot self-signal (`msg.sender == integrators[slotIdx]`); execute permissionless with explicit `slotIdx`; rejects zero address and addresses already taken by another slot; not burnable |
| VestingStream | `CHANGE_RECIPIENT(idx)` | 7d | issuer-signal; non-zero; auto-claims for outgoing; per-allocation burnable |
| BoardwalkClubLockbox / Mirror | `SET_PEER(selector)` | 7d | typed signal only (generic admin + burn disabled); execute permissionless; rejects zero peer; mirror restricted to the Base selector; instant owner `removePeer` is the kill switch |
| BoardwalkClubLockbox | `RESCUE(collection, tokenId)` | 7d | recipient committed in hash; execute permissionless; hard-reverts on escrow-accounted (`locked`) originals |
| BoardwalkClubLockbox | `FORCE_UNLOCK(tokenId)` | **30d** | recipient committed in hash (verified off-chain as the current spoke holder — secondary sales move the claim); requires the token escrowed at signal time; execute permissionless; legitimate release clears any pending signal (bridging back defeats a wrongful one); sole path that releases a `locked` original — backstop for vacuous-SUCCESS deliveries and deprecated lanes, never for FAILED-replayable messages |
| GovernanceVoter | `SET_TREASURY / _KEEPER` | 7d | non-zero |
| GovernanceVoter | `SET_FEE_COLLECTOR` | 7d | non-zero; pair with `BoardwalkFeeCollector.MIGRATE_COLLECTOR` |
| GovernanceVoter | `SET_GOVERNANCE_BURN` | **21d** | 0–1 BWLK |
| GovernanceVoter | `SET_FALLBACK_TREASURY` | **21d** | non-zero; setter itself burnable |
| GovernanceVoter | `setPoolHooks` | none (one-shot) | owner-only, outside `Timelocked`; open only when deployed with `poolHooks == 0`; `execute()` blocks options 2/3/4 until committed |
| RevenueBridger / EthereumRevenueSwapper | `SET_KEEPER` | 7d | non-zero; instant owner `revokeKeeper` is the kill switch (documented exception to the all-admin-Timelocked rule, precedent: lockbox `removePeer`) |
| RevenueBridger | `SET_SELECTOR(selector)` | 7d | add/remove a LiFi facet selector; one shape per lane matching `HAS_SOURCE_SWAPS` |
| RevenueBridger / EthereumRevenueSwapper | `RESCUE(token)` | 7d | `token == address(0)` rescues native, else the ERC20; recipient + amount committed in hash; execute permissionless |

`BoardwalkToken`, `LPStaking`, `PresaleManager`, `BoardwalkLPManager`, and `ParticipationDistributor` have no admin functions. `LPLocker`'s only privileged role is the launch registrar, renounced after the CCA position is registered. `BwlkMigration` is plain `Ownable2Step` (owner = the 21-day timelock): one-shot `setMerkleRoot`, points-only `creditPoints`, and deadline-gated `sweepUnclaimed`.

---

## Governance (Ethereum)

`BoardwalkFeeCollector` splits the post-swap raise-token output **10% to treasury / 90% to `GovernanceVoter`** when `governanceVault` is set; if `governanceVault == address(0)`, 100% routes to treasury. `GovernanceVoter` is a merged voter + executor + vault. Peers (`lpLocker`, `participationDistributor`, `feeCollector`) are wired once via `initializePeers(lpLocker, participationDistributor, feeCollector)` after deployment and validated bidirectionally. The `feeCollector` is the sole address authorised to call `depositRevenue` (`BoardwalkFeeCollector` on Ethereum). Required deploy order: `GovernanceVoter` → `LPLocker(voter)` → `ParticipationDistributor(voter)` → `initializePeers`.

Voting weight comes from the BWLK staking trackers (sbfBWLK balances, bnBWLK multiplier points).

`BoardwalkFeeCollector.executeSetGovernanceVault(vault)` enforces `IGovernanceVoter(vault).WETH() == RAISE_TOKEN` for any non-zero vault: `depositRevenue` pulls WETH while the collector forwards `RAISE_TOKEN`, so the wiring is only valid where the raise token is WETH.

### Collector migration choreography

`executeMigrateCollector` retargets all FeeDistributors to a new collector. The new collector's `swapToRaiseToken` will call `IGovernanceVoter.depositRevenue`, which only accepts the bound `feeCollector`. A fresh collector also starts with `governanceVault == address(0)`, so until that is set the 90/10 split is skipped and 100% routes to treasury. On the OLD side: a collector with `governanceVault = voter` still set would try to forward 90% to the voter on any subsequent `swapToRaiseToken()` and revert (`NotFeeCollector`) once the voter rotates away, so its `governanceVault` must be cleared before its residual balance can drain to treasury.

A complete migration requires FOUR timelocked signals, all 7-day delay, all signed at the same time:

1. **New collector**: `signalAction(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(voter)))`. Sets `governanceVault` on the new collector. The `IGovernanceVoter(voter).WETH() == RAISE_TOKEN` guard fires here. Execute only AFTER step 4 executes — a collector whose vault points at a voter that does not recognise it bricks its own swap path (`depositRevenue` has no try/catch).
2. **Old collector**: `signalAction(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(address(0))))`. Clears the old collector's vault so its post-migration `swapToRaiseToken()` falls through to the treasury-only branch.
3. **Old collector**: `signalAction(ACTION_MIGRATE_COLLECTOR, keccak256(abi.encode(newCollector, distributors)))`. Switches every FD to the new collector.
4. **Governance voter**: `signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(newCollector)))`. Rotates the sole `depositRevenue` caller.

After all four execute, the new collector is the sole `depositRevenue` caller, the old collector is locked out of governance routing, and any pre-rotation residual on the old collector can be drained 100% to treasury. The same ordering applies to a fresh-deployment cutover (no launches on the old stack): deploy the new collector vault-unset, signal the voter's `SET_FEE_COLLECTOR` and the collector's `SET_GOVERNANCE_VAULT` together, execute the voter rotation first.

### Weekly cycle

Votes in epoch `N` decide the winner of epoch `N+1`. Epoch 0 always defaults to treasury (no prior votes).

1. **`vote(option)`**: sbfBWLK holders cast a vote weighted by `sbfBWLK.balanceOf(voter)` at vote time. Voting requires `stakedMP >= stakedBWLK * 1.5%` (participation-points gate, read from the external staking trackers). Optional `governanceBurn` BWLK burn per vote (0–1 BWLK, 21-day timelocked, starts at 0). Reverts during finalization.
2. **`finalize(epoch, maxBatch)`**: keeper-or-owner. Re-validates epoch `N-1` voters in batches (re-reads `sbfBWLK.balanceOf(voter)`, reduces option weights for voters whose balance dropped). When all batches done: closes the finalization window, applies quorum and consecutive-win cap, picks the winner. Sets `e.budget = epochRevenue[N]`, the WETH that `BoardwalkFeeCollector` deposited via `depositRevenue` while epoch `N` was current. Per-epoch revenue invariant: governance budget follows when WETH enters the governance vault; keeper-driven swap timing controls the attribution.
3. **`execute(epoch, amountOutMin, liquidity, deadline)`**: keeper-or-owner. Executes the finalized winner with caller-supplied slippage protection. `liquidity` is used by Option 3 (Buy & Burn LP); ignored otherwise. Decrements `accountedBudget` by the consumed amount.
4. **`forceMarkExecuted(epoch)`**: permissionless, callable 14 days after `finalizedAt[epoch]`. The window is anchored to the finalize timestamp (not epoch end) so the keeper always has a full 14 days to retry execute even after a late finalize. Routes the budget to `fallbackTreasury`, decrements `accountedBudget`, marks executed. Deadlock resolver only.

**Sequential rule**: epoch `N` cannot be finalized until epoch `N-1` is both finalized AND executed.

### Quorum and winner selection

- `snapshotTotalWeight` = `sbfBWLK.totalSupply()` snapshotted at finalize-time of the prior epoch (or first vote if missed).
- `quorumBase = max(snapshotTotalWeight, sbfBWLK.totalSupply() at finalize)`. A first voter who deflated supply pre-snapshot cannot lower quorum below the live supply at finalize.
- Quorum threshold: `eligibleVoteWeight >= quorumBase * 51%`. `eligibleVoteWeight` excludes votes for any option that is ineligible at finalize time, so majority votes for an option that becomes ineligible no longer inflate quorum on behalf of a minority option.
- Zero supply or zero `eligibleVoteWeight` → quorum fails safely (no division by zero).
- Ineligible options (consecutive-win cap reached) are skipped during winner selection.
- No quorum, or no eligible option qualifies: winner defaults to treasury.

**Consecutive-win cap**: any option winning 3 consecutive epochs is ineligible for the next epoch, then becomes eligible again.

### Vote options

| Option | Action |
| ------ | ------ |
| 1. Treasury | Send raise token to `treasury` |
| 2. Buy & Burn BWLK | Unwrap WETH → ETH, swap ETH→BWLK via Universal Router (v4 native ETH), burn to dead |
| 3. Buy & Burn LP | Split 50/50. Swap half to BWLK via Universal Router (`V4_SWAP`). Mint a Uniswap v4 LP position (ETH/BWLK, currency0 = `address(0)`) by calling `PositionManager.modifyLiquidities()` directly. Action sequence: `MINT_POSITION + SETTLE(ETH, OPEN_DELTA) + SETTLE(BWLK, OPEN_DELTA) + SWEEP(ETH→voter) + SWEEP(BWLK→voter)`. BWLK is pre-funded to the PositionManager so `SETTLE(payerIsUser=false)` pays from PM's own balance. Tick bounds are `TickMath.{min,max}UsableTick(POOL_TICK_SPACING)`. Send NFT to `LPLocker`. Residual BWLK → DEAD, residual ETH → treasury via WETH wrap. Caller supplies `liquidity` and slippage. |
| 4. Participation | Swap to BWLK (via ETH), stream to eligible voters (`ParticipationDistributor`, 7-day linear, eligibility = voted in prior epoch) |

Options 2, 3, and 4 all trade through the pool key built from `POOL_FEE / POOL_TICK_SPACING / POOL_HOOKS`; `execute()` reverts `PoolHooksNotSet` for all three until the one-shot `setPoolHooks` commits the hook (see *BWLK token and migration*).

### Native ETH (v4)

Uniswap v4 pools use native ETH (`address(0)`), not WETH. `GovernanceVoter` unwraps WETH via `IWETH(WETH).withdraw()` before swaps and mints, sends ETH via `msg.value`, and uses `address(0)` as currency0 in pool keys. The `receive()` function accepts ETH from WETH and PositionManager only. Leftover ETH from Option 3 is `SWEEP`-recovered, re-wrapped, and forwarded to treasury.

### Batch-finalization invariants

- `finalizationInProgress = true` blocks `vote()` (prevents balance inflation mid-tally).
- `validationCursor[epoch]` advances per batch; a single `finalize(N)` call can complete in N batches.
- `finalizingEpoch` prevents one-shot bleed-over to the next epoch.
- `accountedBudget` is the running sum of finalized-but-not-executed budgets; never derived from a balance-of read, so direct WETH transfers to the voter do not affect the accounting.

### Supporting contracts

- **LPLocker**: permanent holder of Uniswap v4 LP NFTs. Two registration paths: `lockPosition(tokenId)`, callable only by `GovernanceVoter` after an Option 3 mint, and registrar-gated `registerPosition(tokenId)` for the CCA launch positions — the locker must own the NFT, the voter's hook must be committed, and the full pool key (currencies, fee, tick spacing, hooks) must match the voter's pool; the registrar renounces after the launch. No `onERC721Received` is implemented, so external `safeTransferFrom` reverts at the destination. `claimFees(tokenId)` (and the batch `claimAllFees()`) call `PositionManager.modifyLiquidities()` with `DECREASE_LIQUIDITY(liquidity=0) + TAKE_PAIR`; the ETH portion is sent natively to `GovernanceVoter.treasury()` (read live).
- **ParticipationDistributor**: 7-day linear BWLK streams per epoch. Pull-based: voters from the prior epoch call `claim(epoch)` for their proportional share. `claimAll(epochs[])` reverts if nothing is claimable across the entire batch.

### Deployment caveats

The live deployment targets Ethereum mainnet's canonical v4 `UniversalRouter` (`0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af`), and `_swapRaiseTokenForBwlk` encodes the `V4_SWAP` path with the `0x140`-length `ExactInputSingleParams` layout used by that router revision. Overriding `UNIVERSAL_ROUTER` to a newer revision (some newer UR builds expect an extra `minHopPriceX36` field) MUST update `_swapRaiseTokenForBwlk`'s calldata accordingly, or swaps will silently revert.

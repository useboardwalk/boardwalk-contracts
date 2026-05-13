# Boardwalk Launchpad — Technical Spec

A permissionless token launch protocol with embedded transfer tax, time-weighted presale, permanently locked liquidity, LP staking, community ranking, and (on Base) onchain governance over its own protocol revenue. Each launch deploys 4–5 EIP-1167 clones from shared implementation templates. Singletons are deployed once per chain.

Targeted chains: Ethereum, Base, Katana, Fraxtal. The raise token (WETH, frxUSD, etc.) is set per chain at deployment.

---

## Architecture

**Per-launch clones** (deployed by `LaunchFactory.createLaunch`):
- `BoardwalkToken` — ERC20 with embedded tax
- `FeeDistributor` — routes tax to recipients
- `PresaleManager` — contributions, seeding, claims, refunds
- `LPStaking` — staking with vesting + fee epochs + MP
- `VestingStream` — linear vesting (Advanced path only when `presalePercent < 50%`)

**Singletons** (deployed once per chain):
- `LaunchFactory`, `BoardwalkLPManager`, `BoardwalkFeeCollector`, `BoostBurn`
- Base only: `GovernanceVoter`, `LPLocker`, `ParticipationDistributor`

Each clone is initialised exactly once. `LPStaking` and `VestingStream` use a two-step `setInitializer` → `initialize` lock so only `PresaleManager` can initialise them at seed time. `BoardwalkToken`, `FeeDistributor`, and `PresaleManager` use OZ `Initializable` (`_disableInitializers()` in constructor, `initializer` modifier on `initialize`). Express launches deploy 4 clones (no VestingStream).

---

## Launch paths

|                       | EXPRESS                         | ADVANCED                                                    |
| --------------------- | ------------------------------- | ----------------------------------------------------------- |
| Presale duration      | 24h (configurable, > 0)         | 7d default (admin range 2–14d)                              |
| Presale allocation    | Fixed 50%                       | 25–50%, divisible by 5%                                     |
| Start delay           | None                            | 24h                                                         |
| Vesting               | Disallowed                      | Up to 5 recipients; required if `presalePercent < 50%`      |
| Referrer              | Disallowed                      | Optional; can be one of the vesting recipients              |
| Issuer fee recipients | 1                               | 1–4                                                         |

Path is part of the immutable `LaunchInfo`. Path-specific validation in `LaunchFactory` rejects mixed configurations (e.g. Express with vesting reverts).

---

## Token allocation

Total supply is fixed at **`TOTAL_SUPPLY = 10_000_000_000e18`** (10 billion) for every launch. Splits computed by `AllocationLib.compute(TOTAL_SUPPLY, presalePercent)`:

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

The DEX layer is a forked Uniswap V2 with a 0.1% (10 BPS) pair fee that flows to LP holders. The token tax stacks with the pair fee on swaps, so a user trading through a launch's pool pays an effective **~1.25% per swap** (115 BPS tax on the transfer to the pair + 10 BPS pair fee on the swap leg). The tax goes to the protocol's six fee buckets (see *Fee distribution*); the LP fee accrues to the pool's permanently-locked liquidity.

**Tax rate** (in BPS):
- Before seed (`liquiditySeedTime == 0`): tax disabled (transfers tax-free, but the only minter is `PresaleManager`).
- During anti-whale (first `antiWhaleDuration` after seed): `tax = antiWhaleTaxBps - (antiWhaleTaxBps - baseTaxBps) * elapsed / antiWhaleDuration`.
- After: `baseTaxBps`. Default 115 BPS (1.15%).

`baseTaxBps`, `antiWhaleTaxBps`, and `antiWhaleDuration` are all set at `initialize` and frozen for the life of the token. `LaunchFactory` admins can configure the anti-whale parameters per future launch via `executeSetAntiWhale(taxBps, duration)` within bounds `taxBps ∈ [500, 4000]` (5%–40%) and `duration ∈ [5 min, 90 min]`. `baseTaxBps <= antiWhaleTaxBps` is enforced so the linear-decay formula cannot underflow. `liquiditySeedTime` is set exactly once by `PresaleManager.seedLiquidity()`; `setLiquiditySeedTime(0)` reverts to preserve the sentinel, and future timestamps are rejected.

**Exemption list** (set at `initialize`):

| Address                              | Reason                                                              |
| ------------------------------------ | ------------------------------------------------------------------- |
| `FeeDistributor`                     | Receives tax; exemption prevents recursive tax on the callback path |
| `PresaleManager`                     | Mints initial supply; presale claims after cliff are tax-free       |
| `VestingStream`                      | Vesting claims are tax-free                                         |
| `LPStaking`                          | Reward distribution and fee inflows are tax-free                    |
| `BoardwalkLPManager`                 | Tax-exempt LP add/remove wrapper                                    |
| `BoardwalkFeeCollector`              | Keeper batch-swaps to raise token are tax-free                      |
| `IntegratorFeeRecipientCollector`*   | Receives integrator share via `safeTransfer`; `batchClaim` to owner is tax-free |
| `AncillaryFeeRecipientCollector`*    | Receives ancillary share via `safeTransfer`; `batchClaim` to owner is tax-free |

*Conditional on the chain having a non-zero BPS for that role (e.g. ETH mainnet has no integrator).

Post-init mutations of the exempt set are restricted to `feeDistributor`-only and limited to **three** self-sovereign rotation flows: `setFeeCollector` (boardwalk migration), `executeChangeIntegratorAddress`, and `executeChangeAncillaryAddress`. Each rotates exemption atomically with the role address.

---

## Fee distribution

The split is **frozen per launch** at `FeeDistributor.initialize`. Chain-specific defaults (set at `LaunchFactory` deployment, applied to future launches):

**Base / Katana / Fraxtal** — both integrator and ancillary collectors:

| Recipient    | BPS | Notes                                                            |
| ------------ | --- | ---------------------------------------------------------------- |
| Issuer       | 30  | Claim as raise token, 10%-of-accrued / 24h limit                 |
| Boardwalk    | 35  | Forwarded to `BoardwalkFeeCollector` via `receiveFees` (try/catch) |
| LP staking   | 23  | Forwarded to `LPStaking.notifyFees` (try/catch)                  |
| Referrer     | 5   | **Carved out of boardwalk** (not additive); accrues for pull claim |
| Integrator   | 25  | Pushed to integrator collector via `safeTransfer` + `notifyFees` |
| Ancillary    | 2   | Pushed to ancillary collector via `safeTransfer` + `notifyFees`  |
| **Total**    | **115** |                                                              |

**Ethereum mainnet** — ancillary only (no integrator):

| Recipient    | BPS | Notes                                                            |
| ------------ | --- | ---------------------------------------------------------------- |
| Issuer       | 40  |                                                                  |
| Boardwalk    | 45  |                                                                  |
| LP staking   | 28  |                                                                  |
| Referrer     | 5   | Carved from boardwalk                                            |
| Integrator   | 0   | Not configured on ETH mainnet                                    |
| Ancillary    | 2   |                                                                  |
| **Total**    | **115** |                                                              |

Referrer carve-out: when a referrer is set, `boardwalkEffective = boardwalk - referrer`. Total tax stays 115 BPS regardless. Integrator and referrer are NOT mutually exclusive on Base/Katana/Fraxtal — both can coexist on Advanced launches.

**Per-transfer routing in `onTaxReceived`:**
1. Compute `lp/boardwalk/issuer/referrer/integrator/ancillary` shares (proportional by frozen BPS).
2. `try LPStaking.notifyFees(lpShare)` — on revert, `pendingLpFees += lpShare`, emit `FeeForwardFailed`.
3. `try FeeCollector.receiveFees(token, boardwalkShare)` — on revert, `pendingBoardwalkFees += boardwalkShare`.
4. **Push integrator/ancillary** via `_forwardThirdParty(addr, share)`: `safeTransfer(addr, share)` (always lands; both endpoints are exempt) followed by best-effort `try notifyFees(token, share) {} catch { emit FeeForwardFailed("Notify", _) }`. **No allowance is granted** to partner-controlled collectors and **no `pending*` queue** is added — the residual failure surface is too small to justify the extra storage / retry path.
5. Distribute issuer share across recipients by frozen splits; last recipient gets the remainder to absorb rounding dust.
6. Increment `referrerAccrued`.

`retryPendingFees()` is permissionless and flushes any accumulated failed LP/Boardwalk forwards. Steps 1–6 never revert as a unit, so transfers cannot be bricked by a downstream contract.

**Issuer claim** (`claimAsRaiseToken`): rate-limited to 10% of `totalAccrued` per recipient per 24h, swapped via the standard router (`FeeDistributor` is exempt). Dust escape: if `totalAccrued / 10 == 0`, the full unclaimed amount is claimable in one call. Caller supplies `minRaiseTokenOut` and `deadline`.

**Integrator/ancillary claim** lives on the recipient `FeeRecipientCollector`, not on `FeeDistributor`: the collector tracks tokens via `EnumerableSet` (gated by `IBoardwalkToken(token).feeDistributor() == msg.sender`) and exposes `batchClaim(uint256 limit)` to its owner — claim amount is `IERC20(token).balanceOf(address(this))` per token (no accrual mapping). The collector is partner-controlled (`Ownable2Step`); rescue paths `claimToken(token)` and `removeTrackedToken(token)` cover untracked balances and junk-token grief.

**Per-recipient address changes**: only the current recipient can `signal` and `cancel`; anyone can `execute` after the delay. Claims continue to flow to the OLD address until execute. Non-zero address validated in execute. Integrator/ancillary execute paths additionally rotate the BoardwalkToken exemption (`updateExempt(old, false)`; `updateExempt(new, true)`) and enforce `IBoardwalkToken(token).isExempt(newAddress) == false` to prevent exempt-list aliasing. Delay differs per role:

- Issuer / referrer: **7 days** (default).
- Integrator / ancillary: **14 days** (per-clone enforced inside `FeeDistributor` via `_actionDelay` override). The longer window is a hard protocol-level minimum; no role-holder can rotate faster regardless of how its own controller is structured.

**Fee collector rotation** (`FeeDistributor.setFeeCollector`, called by the current `feeCollector` only): atomically (a) `updateExempt(old, false)` then `updateExempt(new, true)` on the token, (b) revoke approval to old, grant max approval to new. Same `isExempt` distinct-address invariant applies. No timelock — `BoardwalkFeeCollector`'s own `MIGRATE_COLLECTOR` action provides the delay at the singleton level.

`FeeDistributor` blocks the generic `signalAction` path (`_authAdmin` always reverts); only the typed issuer/referrer/integrator/ancillary flows mutate state.

**Factory-level integrator/ancillary rotation** (`LaunchFactory.signalChangeIntegratorAddress` / `…AncillaryAddress`): same self-sovereign pattern, `msg.sender == role`, **14-day delay**. Affects future launches only — past clones retain their frozen role addresses. `LaunchFactory._authAdmin` reverts for `ACTION_SET_INTEGRATOR` / `ACTION_SET_ANCILLARY` so the owner cannot rotate via the generic timelock path.

**Cross-clone migration UX** — the default `FeeRecipientCollector` exposes batched typed helpers so a partner can rotate the role across many clones in 2 transactions instead of 2N: `signalChangeOnDistributors(distributors[], newAddress)` (owner-only, loops the per-FD typed signal), `executeChangeOnDistributors(distributors[], newAddress)` (permissionless, mirrors FD's permissionless execute), `cancelChangeOnDistributors(distributors[])` (owner-only). Each helper auto-detects whether the collector currently holds the integrator OR ancillary role per FD. Factory-side rotation goes through the parallel `signalChangeOnFactory(factory, newAddress)` / `cancelChangeOnFactory(factory)`. The FD's per-clone 14-day timelock applies regardless — the helpers are pure UX glue.

---

## Presale

**Lifecycle** (`PresaleManager`):
1. `contribute(amount)` during `[presaleStart, presaleEnd]`. Each contribution gets a time-decayed bonus multiplier `bonus = 11_000 → 10_000` over the window (10% bonus at start, 0% at end). `weightedWeth = amount * bonus / 10_000`. Per-user `contributions[user]` tracks `totalWeth` and `weightedWeth`; `totalWeightedWeth` aggregates.
2. After `presaleEnd + 1h` (`SEED_DELAY`), `seedLiquidity()` is permissionless. If `totalWethRaised >= graduationThreshold`:
   - `AllocationLib.compute()` → mints to PresaleManager (presale + liquidity), LPStaking (incentive), VestingStream (issuer vesting if applicable).
   - Transfers token + raise token directly to the pair, calls `pair.mint(DEAD_ADDRESS)`. LP tokens are unrecoverable.
   - Initialises `LPStaking` and (if applicable) `VestingStream` with `seedTime`.
   - Calls `token.setLiquiditySeedTime(seedTime)` — anti-whale tax begins counting down.
3. After seed + 7-day cliff, `claimTokens()` pays out `userTokenAmount = user.weightedWeth * presaleTokens / totalWeightedWeth` (O(1)).
4. If presale fails (under threshold by `seedLiquidity()` time), `refund()` returns each user's `totalWeth`.

`setVestingConfig(recipients[], amounts[])` is called by `LaunchFactory` exactly once for Advanced launches. Constructor validates `IRouterFactory(router).factory() == dexFactory`.

**Mint authority:** only `PresaleManager` can call `token.mint(...)`. Total minted is bounded by `TOTAL_SUPPLY` (enforced inside `mint`).

---

## LP staking

`LPStaking` has **zero admin functions** — fully immutable after `initialize`. Two reward streams flow to a single weight-based accumulator:

**Vesting reward** (continuous, 3-year linear from `vestingStart = seedTime + 24h` to `vestingStart + 3 years`):
```
baseVestingRate = vestingAllocation / VESTING_DURATION   // tokens per second
vestingDelta    = elapsed * baseVestingRate
```

**Fee reward** (weekly epochs, anchored to trigger time):
```
feeRewardRate    = currentEpochFees / 7 days
feeDelta         = elapsed * feeRewardRate
```

Epoch advancement happens lazily inside `_updateAllRewards()`, called by every `stake / withdraw / claim / notifyFees`. When `block.timestamp >= currentEpochStart + 7 days`:
- `currentEpochFees ← pendingEpochFees`, `pendingEpochFees ← 0`
- `feeRewardRate = currentEpochFees / 7 days`
- `currentEpochStart ← block.timestamp` (anchored to trigger, not boundary)

`notifyFees` is the most reliable trigger because it fires on every taxed transfer. It is called by `FeeDistributor` (tax-exempt sender) and writes to `LPStaking` (tax-exempt receiver), so reentrancy is impossible by construction; `nonReentrant` is omitted. The caller wraps the call in try/catch.

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

MP is **lazily crystallised** on user interactions. Active users accrue MP sooner than inactive ones (accepted tradeoff).

**Pending reward ordering**: pending rewards are settled with the OLD weight before MP is updated, preventing post-update inflation from stealing prior accumulator value.

**Zero-staker periods**: when `totalWeight == 0`, both vesting and fee rewards for the elapsed interval are **permanently lost** — `lastRewardUpdate` advances without distribution. Intentional: prevents unbounded carryover.

---

## Vesting

`VestingStream` is per-launch (Advanced only), supports up to 5 recipients, and is immutable after `initialize` except for recipient address changes.

```
cliffEnd    = seedTime + 7 days
vestingEnd  = cliffEnd  + 3 years
claimable(i) = (block.timestamp - cliffEnd) * allocations[i].amount / 3 years - allocations[i].claimed
```

Claims revert before `cliffEnd`. Vesting amounts, schedule, and labels are immutable; only recipient addresses can change.

**Recipient changes** are issuer-controlled and use the generic `Timelocked` `signalAction(action, dataHash)` / `cancelAction(action)` path with `_authAdmin == issuer`. The typed `executeChangeRecipientAddress` performs the state mutation after the 7-day delay; it auto-claims any vested-but-unclaimed tokens for the **outgoing** recipient before switching. Per-allocation `signalBurnAction / executeBurnAction` makes a recipient address permanently immutable.

`VestingStream` is in the token's exempt list, so vesting claims do not pay tax.

---

## Per-contract notes

### BoardwalkToken (clone)
ERC20 + Initializable. Constructor calls `_disableInitializers()`. `name()` / `symbol()` overridden to return clone-specific values. Custom `TokenInitialized` event avoids collision with OZ `Initialized(uint64)`. No owner; the only mutator beyond `initialize` is `feeDistributor` calling `updateExempt` during collector rotation.

### FeeDistributor (clone)
Inherits `Timelocked` + `Initializable`, but `_authAdmin` always reverts so the generic signal path is dead. Typed issuer/referrer/integrator/ancillary signal/cancel/execute flows are the only state-mutating admin paths. Burns are intentionally not exposed (recipient-controlled changes are self-sovereign). `pendingLpFees / pendingBoardwalkFees` accumulate when downstream forwards revert; `retryPendingFees()` flushes them. Integrator and ancillary use **push+notify** (`safeTransfer` + best-effort `notifyFees`) — no allowance, no pending queue, no claim function on FeeDistributor.

### PresaleManager (clone)
Initializable. `setVestingConfig` is a one-shot factory-only call. After `seedLiquidity`, the only ongoing function is `claimTokens` (or `refund` if failed). No admin.

### LPStaking (clone)
ReentrancyGuardTransient + Initializable. Two-step initialiser lock (`setInitializer` then `initialize`). Zero admin functions.

### VestingStream (clone)
Timelocked + Initializable. Two-step initialiser lock with `issuer` set at the same time. Issuer-only timelocked recipient changes (described above).

### LaunchFactory (singleton)
Ownable2Step + Timelocked + MembershipDiscount. Holds implementation addresses (immutable), DEX/router/LPManager addresses (immutable), raise-token address (immutable), per-chain graduation thresholds (mutable, timelocked), fee BPS defaults (timelocked, frozen at clone init), presale range, durations, BMX burn amount, NFT collection, member discount BPS, **integrator and ancillary collector addresses (constructor-set, self-sovereign rotation)**, **anti-whale tax/duration (timelocked, applied to future clones)**. On `createLaunch`: validates config (including distinct-address invariant against immutable exempt singletons), burns `_effectiveCost(bmxBurnAmount, memberLaunchDiscountBps, msg.sender)` BMX from issuer to dead, deploys clones, locks LPStaking/VestingStream initialisers, initialises Token (with anti-whale config) / FeeDistributor (with all six fee buckets and integrator/ancillary collector addresses) / PresaleManager. Stores `LaunchInfo`, emits `LaunchCreated` (with labels for indexers).

### BoardwalkLPManager (singleton)
Immutable after deploy. `addLiquidity / removeLiquidity` restricted to pairs containing `RAISE_TOKEN`. LP mint/burn through this wrapper is tax-free by design (the wrapper is in every launch token's exempt list).

### BoardwalkFeeCollector (singleton)
Ownable2Step + Timelocked. Aggregates inbound boardwalk-share tokens from all FeeDistributors. `swapToRaiseToken(tokens[], minAmountsOut[])` is keeper-only and uses standard `swapExactTokensForTokens` (the collector is exempt). Approves the router lazily with `forceApprove(ROUTER, type(uint256).max)` once per token. Output raise token is forwarded to `treasury` (and on Base, split 30/70 to treasury/`GovernanceVoter` — see below). Migration (`executeMigrateCollector(newCollector, distributors[])`) commits both arguments in the signal hash so partial execution is impossible.

### FeeRecipientCollector (singleton-per-role)
Ownable2Step. Per-role aggregator (integrator OR ancillary) for fees pushed via `safeTransfer` from every launch's FeeDistributor; a best-effort `notifyFees(token, amount)` registers the token in an `EnumerableSet` (gated by `IBoardwalkToken(token).feeDistributor() == msg.sender` to bound junk-token grief). Owner self-services `batchClaim(uint256 limit)` to drain accumulated balances — claim amount is `IERC20(token).balanceOf(address(this))` per token (no accrual mapping; handles late-arriving and donation balances). `batchClaim` iterates downward against a snapshot of the original set length and wraps each per-token transfer in `try/catch` via `_safeClaimTo`, so a malicious tracked token cannot brick the batch or starve other entries via reentry-readd; failed tokens are removed from the set and emit `ClaimFailed`. Owner-only rescue: `claimToken(token)` for untracked balances, `removeTrackedToken(token)` to delist junk. Cross-clone rotation helpers (`signalChangeOnDistributors` / `executeChangeOnDistributors` / `cancelChangeOnDistributors`) batch the per-FD typed signal/execute/cancel paths so an N-clone migration takes 2 owner transactions; each auto-detects the collector's role per FD. Factory-side helpers (`signalChangeOnFactory` / `cancelChangeOnFactory`) cover rotation on the singleton. Trust model: partner-controlled (NOT protocol-controlled like `BoardwalkFeeCollector`) — no allowance is granted by `FeeDistributor` to the collector, narrowing the trust surface to the collector's own balance. The 14-day rotation delay is enforced inside `FeeDistributor` and `LaunchFactory`, not here, so EOA / non-Timelocked role-holders cannot shortcut it.

### BoostBurn (singleton)
Ownable2Step + Timelocked + MembershipDiscount. Maps `int256 scores[token]`. Each `(wallet, token, epoch)` can boost or deboost once. Cost is `_effectiveCost(bmxCost, memberBoostDiscountBps, msg.sender)` BMX, burned to dead. `epoch = (block.timestamp - EPOCH_ZERO) / 30 days` (epoch duration immutable). No factory validation — accepts any token address.

### MembershipDiscount (base)
Shared NFT membership check. `_isMember(account)` returns false when `nftCollection == address(0)` (no external call). `_effectiveCost(base, bps, account)` applies the discount only for members.

### Timelocked (base)
Generic `signalAction(action, dataHash) / cancelAction(action) / typed execute*` pattern. Per-action delay via `_actionDelay(action)` virtual hook (default 7 days; GovernanceVoter overrides to 21 days for governance-sensitive actions). 7-day expiry window after delay elapses. Per-action permanent **burn** flow (`signalBurnAction / executeBurnAction / cancelBurnAction`); burn delay defaults to the action's delay. A burned action can never be signalled, executed, or unburned. `_authAdmin(action)` is the only auth hook — owner-controlled inheritors implement `onlyOwner`.

---

## Cross-contract flows

### 1. Launch creation (`LaunchFactory.createLaunch`)
1. Validate config (path, presale percent divisibility, vesting required when `presalePercent < 50%`, splits sum, address bounds).
2. Burn `_effectiveCost(bmxBurnAmount, memberLaunchDiscountBps, issuer)` BMX from issuer to dead.
3. Deploy clones (token, feeDistributor, presale, lpStaking; vesting if Advanced + needs vesting).
4. Lock `LPStaking.initAuthorizer = presale`. Lock `VestingStream.initAuthorizer = presale, issuer = issuer`.
5. Initialise token (name, ticker, baseTaxBps, antiWhaleTaxBps, antiWhaleDuration, feeDistributor, presale, exempt addresses).
6. Initialise feeDistributor (token, lpStaking, feeCollector, router, raiseToken, issuerRecipients[], issuerSplits[], referrer, integrator, ancillary, all six bucket BPS).
7. Initialise presale (all clone addresses, raiseToken, duration, presalePercent, graduationThreshold, startDelay flag).
8. If Advanced + needs vesting: call `presale.setVestingConfig(recipients, amounts)`.
9. Store `LaunchInfo`, emit `LaunchCreated`.

### 2. Presale → seed → claim
1. Users `contribute(amount)` during the window. `weightedWeth` is computed with the live time-decay multiplier and added to per-user and global totals.
2. After `presaleEnd + 1h`, anyone calls `seedLiquidity()`. Mints all four buckets, transfers token + raise token to the DEX pair, calls `pair.mint(DEAD_ADDRESS)`, initialises LPStaking and (if applicable) VestingStream, sets `liquiditySeedTime`.
3. After `seedTime + 7 days`, contributors call `claimTokens()`.
4. If under threshold at `seedLiquidity()` time, `refund()` returns `totalWeth`.

### 3. Transfer → tax → distribution
1. Non-exempt sender transfers — `BoardwalkToken._update` checks both endpoints against `isExempt`.
2. Tax computed (anti-whale or base), debited from amount, transferred to FeeDistributor.
3. `FeeDistributor.onTaxReceived(tax)`: split, try-forward LP and boardwalk shares, push integrator and ancillary shares (`safeTransfer` + best-effort `notifyFees{gas:150_000}`), accrue issuer and referrer shares.
4. (LP path) `LPStaking.notifyFees(lp)` → `_updateAllRewards()` (which may advance the epoch) → if `totalWeight > 0`: `pendingEpochFees += lp`; if `totalWeight == 0`: **the amount is burned to `DEAD_ADDRESS` and `FeesLost(lp)` is emitted** so a first staker after a dormancy window cannot harvest fees that arrived while there were no stakers.
5. (Boardwalk path) `FeeCollector.receiveFees(token, share)` → `accumulatedFees[token] += share`.
6. (Integrator/ancillary path) `FeeRecipientCollector.notifyFees(token, share)` registers the token in the collector's `EnumerableSet`. The preceding `safeTransfer` already landed value; owner drains via `batchClaim`.

### 4. Stake / withdraw / claim
- **Stake**: `_updateAllRewards()` → settle pending with OLD weight → `_updateUserMp(user)` (accrues MP) → pull LP → update `lpStaked`, `totalWeight`, `rewardDebt`.
- **Withdraw**: same prefix → compute `mpToBurn = mp * amount / lpStaked` → decrement `lpStaked`, `multiplierPoints`, `totalWeight` → set new `rewardDebt` → push LP.
- **Claim**: `_updateAllRewards()` → compute pending with STORED weight → push reward token → `_updateUserMp(user)` → recalc debt.

### 5. Keeper batch swap
1. Keeper calls `BoardwalkFeeCollector.swapToRaiseToken(tokens[], minAmountsOut[])`.
2. For each token: read balance, lazy `forceApprove(router, max)` if undersized allowance, swap, clear `accumulatedFees[token]`.
3. Forward all output raise token to `treasury` (or split 30/70 with `GovernanceVoter` on Base).

### 6. Governance vote → finalize → execute (Base only)
See *Governance* section below.

---

## Admin and timelocks (summary)

All admin actions go through `Timelocked.signalAction(action, dataHash) → typed execute*(...)` after the delay (7 days default, 21 days for governance-sensitive actions, 7-day expiry window). Owners can `cancelAction` any time before execute; anyone can execute once delayed. Any owner-controlled action can be permanently burned via `signalBurnAction / executeBurnAction`.

| Contract | Action | Delay | Constraints |
| -------- | ------ | ----- | ----------- |
| LaunchFactory | `SET_BMX_BURN` | 7d | ≤ 200e18; burnable |
| LaunchFactory | `SET_GRADUATION_EXPRESS / _ADVANCED` | 7d | > 0 |
| LaunchFactory | `SET_EXPRESS_DURATION` | 7d | > 0 |
| LaunchFactory | `SET_ADVANCED_DURATION` | 7d | 2–14 days |
| LaunchFactory | `SET_FEE_DEFAULTS` | 7d | issuer 10–80, boardwalk 10–50, incentive 0–50, referrer 0–10, integrator 0–50, ancillary 0–10, referrer ≤ boardwalk; future launches only |
| LaunchFactory | `SET_ANTI_WHALE` | 7d | tax 500–4000 BPS, duration 5–90 min; future launches only |
| LaunchFactory | `SET_PRESALE_RANGE` | 7d | 500–5000 BPS, divisible by 500 |
| LaunchFactory | `SET_FEE_COLLECTOR` | 7d | non-zero, distinct from integrator/ancillary/lpManager; future launches only |
| LaunchFactory | `SET_INTEGRATOR` | **14d** | **self-sovereign** (`msg.sender == integrator`); non-zero in execute; distinct from other exempt addresses; not burnable; future launches only |
| LaunchFactory | `SET_ANCILLARY` | **14d** | **self-sovereign** (`msg.sender == ancillary`); non-zero in execute; distinct from other exempt addresses; not burnable; future launches only |
| LaunchFactory | `SET_NFT_COLLECTION` | 7d | `address(0)` disables discounts |
| LaunchFactory | `SET_MEMBER_LAUNCH_DISCOUNT` | 7d | ≤ 10000 BPS |
| BoardwalkFeeCollector | `SET_TREASURY / _KEEPER` | 7d | non-zero |
| BoardwalkFeeCollector | `SET_GOVERNANCE_VAULT` | 7d | may be zero (disables governance split) |
| BoardwalkFeeCollector | `MIGRATE_COLLECTOR` | 7d | non-zero `newCollector`; both args committed in hash |
| BoostBurn | `SET_BMX_COST` | 7d | 0–1 BMX |
| BoostBurn | `SET_NFT_COLLECTION / _MEMBER_BOOST_DISCOUNT` | 7d | as LaunchFactory analogues |
| FeeDistributor | `CHANGE_ISSUER(idx) / CHANGE_REFERRER` | 7d | per-recipient self-signal; non-zero in execute; not burnable |
| FeeDistributor | `CHANGE_INTEGRATOR / CHANGE_ANCILLARY` | **14d** | per-clone self-signal (`msg.sender == role`); execute rotates exemption + enforces `isExempt(newAddress) == false`; not burnable |
| VestingStream | `CHANGE_RECIPIENT(idx)` | 7d | issuer-signal; non-zero; auto-claims for outgoing; per-allocation burnable |
| GovernanceVoter | `SET_TREASURY / _KEEPER` | 7d | non-zero |
| GovernanceVoter | `SET_FEE_COLLECTOR` | 7d | non-zero; pair with `BoardwalkFeeCollector.MIGRATE_COLLECTOR` |
| GovernanceVoter | `SET_GOVERNANCE_BURN` | **21d** | 0–1 BMX |
| GovernanceVoter | `SET_FALLBACK_TREASURY` | **21d** | non-zero; setter itself burnable |

`BoardwalkToken`, `LPStaking`, `PresaleManager`, `BoardwalkLPManager`, `LPLocker`, and `ParticipationDistributor` have **no admin functions**.

---

## Governance (Base only)

`BoardwalkFeeCollector` splits the post-swap raise-token output **30% to treasury / 70% to `GovernanceVoter`** when `governanceVault` is set. `GovernanceVoter` is a merged voter + executor + vault. Peers (`lpLocker`, `participationDistributor`, `feeCollector`) are wired once via `initializePeers(lpLocker, participationDistributor, feeCollector)` after deployment and validated bidirectionally. The `feeCollector` is the sole address authorized to call `depositRevenue` (`BoardwalkFeeCollector` on Base). Required deploy order: `GovernanceVoter` → `LPLocker(voter)` → `ParticipationDistributor(voter)` → `initializePeers`.

`BoardwalkFeeCollector.executeSetGovernanceVault(vault)` enforces `IGovernanceVoter(vault).WETH() == RAISE_TOKEN` for any non-zero vault: `depositRevenue` pulls WETH while the collector forwards `RAISE_TOKEN`, so the wiring is only valid where the raise token is WETH (currently Base only).

**Collector migration ↔ fee-collector rotation.** `BoardwalkFeeCollector.executeMigrateCollector` retargets all FeeDistributors to a new collector. The new collector's `swapToRaiseToken` will call `IGovernanceVoter.depositRevenue` — which only accepts the bound `feeCollector`. **The new collector also starts with `governanceVault == address(0)`, so until that is set the 70%/30% split is skipped entirely and 100% of swapped raise token routes to treasury.** Mirroring this on the OLD side: after `feeCollector` rotates, the old collector still has `governanceVault = voter` set, so any subsequent `swapToRaiseToken()` on the old collector would try to forward 70% to the voter and revert (`NotFeeCollector`). To unstick the residual-drain path on the old collector, its `governanceVault` must also be cleared.

A complete migration therefore requires FOUR timelocked signals, all 7-day delay, all signed at the same time. `Timelocked.signalAction` commits a `bytes32 dataHash` (`keccak256(abi.encode(...))`), and the typed `execute*` functions re-hash their arguments and require equality:

1. **New collector** — `signalAction(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(voter)))`. Sets `governanceVault` on the new collector. The `IGovernanceVoter(voter).WETH() == RAISE_TOKEN` guard fires here.
2. **Old collector** — `signalAction(ACTION_SET_GOVERNANCE_VAULT, keccak256(abi.encode(address(0))))`. Clears `governanceVault` on the old collector so its post-migration `swapToRaiseToken()` falls through to the treasury-only branch and any residual balance can be drained without bricking on the rotated depositor.
3. **Old collector** — `signalAction(ACTION_MIGRATE_COLLECTOR, keccak256(abi.encode(newCollector, distributors)))`. Switches every FD to the new collector.
4. **Governance voter** — `signalAction(ACTION_SET_FEE_COLLECTOR, keccak256(abi.encode(newCollector)))`. Rotates the sole `depositRevenue` caller.

After all four execute, the new collector is the sole `depositRevenue` caller, the old collector is locked out of governance routing, and any pre-rotation residual on the old collector can be drained 100% to treasury through `swapToRaiseToken()`.

### Weekly cycle

Votes in epoch `N` decide the winner of epoch `N+1`. Epoch 0 always defaults to treasury (no prior votes).

1. **`vote(option)`** — sbfBMX holders cast a vote weighted by `sbfBMX.balanceOf(voter)` at vote time. Voting requires `stakedMP >= stakedBMX * 1.5%` (participation-points gate, read from external Morphex sbfBMX contracts). Optional `governanceBurn` BMX burn per vote (0–1 BMX, 21-day timelocked, starts at 0). Reverts during finalization.
2. **`finalize(N, maxBatch)`** — keeper-or-owner. Re-validates epoch `N-1` voters in batches (re-reads `sbfBMX.balanceOf(voter)`, reduces option weights for voters whose balance dropped). When all batches done: closes the finalization window, applies quorum and consecutive-win cap, picks the winner. Sets `e.budget = epochRevenue[N]`, the WETH that `BoardwalkFeeCollector` deposited via `depositRevenue` while epoch `N` was current. **Per-epoch revenue invariant:** governance budget follows when WETH enters the governance vault — keeper-driven swap timing controls the attribution.
3. **`execute(N, amountOutMin)`** — keeper-or-owner. Executes the finalized winner with caller-supplied slippage protection. Decrements `accountedBudget` by the consumed amount.
4. **`forceMarkExecuted(epoch)`** — permissionless, callable 14 days after `finalizedAt[epoch]`. The window is anchored to the finalize timestamp (not epoch end) so the keeper always has a full 14 days to retry execute even after a late finalize. Routes the budget to `fallbackTreasury` (separate from `treasury`), decrements `accountedBudget`, marks executed. Deadlock resolver only.

**Sequential rule**: epoch `N` cannot be finalized until epoch `N-1` is both finalized AND executed.

### Quorum and winner selection

- `snapshotTotalWeight` = `sbfBMX.totalSupply()` snapshotted at finalize-time of the prior epoch (or first vote if missed).
- `quorumBase = max(snapshotTotalWeight, sbfBMX.totalSupply() at finalize)`. A first voter who deflated supply pre-snapshot cannot lower quorum below the live supply at finalize.
- Quorum threshold: `eligibleVoteWeight >= quorumBase * 51%`. `eligibleVoteWeight` excludes votes for any option that is ineligible at finalize time (e.g. consecutive-win cooldown), so majority votes for an option that becomes ineligible no longer inflate quorum on behalf of a minority option.
- Zero supply or zero `eligibleVoteWeight` → quorum fails safely (no division by zero).
- Ineligible options (consecutive-win cap reached) are skipped during winner selection.
- No quorum, or no eligible option qualifies: winner defaults to treasury.

### Consecutive-win cap

Any option winning 3 consecutive epochs is ineligible for the next epoch, then becomes eligible again.

### Vote options

| Option | Action |
| ------ | ------ |
| 1. Treasury | Send raise token to `treasury` |
| 2. Buy & Burn BMX | Unwrap WETH → ETH, swap ETH→BMX via Universal Router (v4 native ETH), burn to dead |
| 3. Buy & Burn LP | Split 50/50. Swap half to BMX via Universal Router (`V4_SWAP`). Mint a Uniswap v4 LP position (ETH/BMX, currency0 = `address(0)`) by calling `PositionManager.modifyLiquidities()` directly (no Universal Router on the mint path). Action sequence: `MINT_POSITION + SETTLE(ETH, OPEN_DELTA) + SETTLE(BMX, OPEN_DELTA) + SWEEP(ETH→voter) + SWEEP(BMX→voter)`. BMX is pre-funded to the PositionManager so SETTLE(payerIsUser=false) pays from PM's own balance. Tick bounds are `TickMath.{min,max}UsableTick(POOL_TICK_SPACING)`. Send NFT to `LPLocker`. Residual BMX → DEAD, residual ETH → treasury via WETH wrap. Caller supplies `liquidity` and slippage. |
| 4. Participation | Swap to BMX (via ETH), stream to eligible voters (`ParticipationDistributor`, 7-day linear, eligibility = voted in prior epoch) |

### Native ETH (v4)

Uniswap v4 pools on Base use native ETH (`address(0)`), not WETH. `GovernanceVoter` unwraps WETH via `IWETH(WETH).withdraw()` before swaps and mints, sends ETH via `msg.value`, and uses `address(0)` as currency0 in pool keys (ETH always sorts below any contract address). A `receive()` function accepts ETH from WETH and PositionManager only. Leftover ETH after the Option 3 mint is `SWEEP`-recovered back to `GovernanceVoter` (along with leftover BMX), then re-wrapped and forwarded to treasury. Action IDs imported from `@uniswap/v4-periphery/src/libraries/Actions.sol`.

**Universal Router version compatibility:** the default Base deployment targets `UniversalRouter = 0x6fF5693b99212Da76ad316178A184AB56D299b43` and `_swapRaiseTokenForBmx` encodes the V4_SWAP path with the `0x140`-length `ExactInputSingleParams` layout used by that router revision. Overriding `UNIVERSAL_ROUTER` to a newer revision (some newer UR builds expect an extra `minHopPriceX36` field) MUST update `_swapRaiseTokenForBmx`'s calldata accordingly.

### Supporting contracts

- **LPLocker**: holds Uniswap v4 LP NFTs permanently. `lockPosition(tokenId)` (callable only by `GovernanceVoter` after an Option 3 mint) is the sole registration path; no `onERC721Received` is implemented, so `safeTransferFrom` from external accounts reverts at the destination, blocking NFT injection. `claimFees(tokenId)` calls `PositionManager.modifyLiquidities()` with `DECREASE_LIQUIDITY(liquidity=0)` + `TAKE_PAIR` directly (no Universal Router); ETH portion is sent native to treasury (read dynamically from `GovernanceVoter.treasury()`). `claimAllFees()` batches across all locked positions. Open `receive()` for native ETH from PositionManager.
- **ParticipationDistributor**: 7-day linear BMX streams per epoch for Option 4 wins. Pull-based — eligible voters (those who voted in the prior epoch) call `claim(epoch)` for proportional share. `claimable(epoch, user)` returns `(totalAllocation, claimableNow)`. `claimAll(epochs[])` batches across multiple epochs and reverts if nothing is claimable in any of them.

### Batch-finalization invariants

- `finalizationInProgress = true` blocks `vote()` (prevents balance inflation mid-tally).
- `validationCursor[epoch]` advances per batch; a single `finalize(N)` call can complete in N batches.
- `finalizingEpoch` prevents one-shot bleed-over to the next epoch.
- `accountedBudget` is the running sum of finalized-but-not-executed budgets. Incremented from `e.budget = epochRevenue[epoch]` in finalize and decremented in execute / `forceMarkExecuted`. Never derived from a balance-of read, so direct WETH transfers to the voter do not affect the accounting.

---

## Threat model and accepted tradeoffs

- **Zero-staker reward loss**: vesting and fee rewards during `totalWeight == 0` are permanently lost. Intentional — prevents unbounded carryover.
- **Lazy MP crystallization**: MP is only updated on user interactions. Active users effectively earn slightly faster than passive ones for the same staked LP.
- **Issuer rate-limit dust escape**: when total accrued < 10 wei of the fee token, the rate limit is bypassed (otherwise no claim would ever clear). Below the threshold the dust loss to mis-timed claims is negligible.
- **Failed downstream forwarding**: tax delivery never reverts a transfer; bad downstreams accumulate to `pending*Fees` and are flushed by `retryPendingFees`. Loss-of-availability is the worst case, not loss-of-funds.
- **Anti-whale start tax (40% default)**: high enough to deter snipers but creates a steep cost for legitimate early traders. Configurable per future launch via `LaunchFactory.executeSetAntiWhale` within `[500, 4000]` BPS / `[5 min, 90 min]` bounds; frozen per clone at init.
- **`liquiditySeedTime == 0` sentinel**: rejected explicitly (reverts on `setLiquiditySeedTime(0)`); future timestamps also rejected. Prevents tax bypass via post-seed reset.
- **LP burn is unconditional**: failed launches do not seed; successful launches send 100% of LP tokens to dead. There is no path to recover liquidity.
- **Governance keeper liveness**: if neither keeper nor owner finalizes/executes, `forceMarkExecuted` after 14 days routes funds to `fallbackTreasury`. The owner can always re-acquire control.
- **Permissionless seeding**: anyone can call `seedLiquidity()` after the delay, preventing issuer griefing but requiring the issuer (or any participant) to publish the call.
- **No price oracle**: graduation threshold is denominated in raise token units. Volatility of the raise token vs. USD is the issuer's problem to size around.
- **`updateExempt` mutability**: post-init mutation of the exempt set exists exclusively for collector rotation and is restricted to `feeDistributor`. The migration on `BoardwalkFeeCollector` commits both `newCollector` and the FeeDistributor list in the signal hash to prevent partial-state attacks.
- **ParticipationDistributor rounding dust**: per-user allocation is `totalBmx * uv.weight / totalWeight`, rounded down by integer division. Per epoch, at most `numVoters - 1` wei of BMX is left undistributed and stays in `ParticipationDistributor` permanently. Accepted as bounded dust loss.
- **PresaleManager `claimTokens` rounding dust**: per-user `weightedContributed * presaleTokens / totalWeightedRaise` rounds down with the same `numContributors - 1` wei worst case per launch. Accepted on the same reasoning as above.

---

## Notes on tax-exempt contract addresses

Every tax-exempt contract is an immediate counterparty in tax flows. Adding new exempt addresses post-launch is impossible by design — the only post-init mutation is the `feeCollector` swap during a migration. Auditors should treat the exemption list as part of the trust boundary: a compromise of any exempt contract bypasses the tax entirely for tokens transferred through it.

The `BoardwalkLPManager.RAISE_TOKEN` restriction on `addLiquidity / removeLiquidity` is the only structural defence against using exempt contracts as transfer tunnels.

# Boardwalk Launchpad -- Executive Summary

## What it is

Boardwalk Launchpad is a permissionless token launch protocol with built-in transfer taxes, time-weighted presales, permanent liquidity, LP staking, community ranking, and onchain governance. Each launch deploys a set of lightweight proxy contracts from shared templates.

**Multi-chain:** Ethereum, Base, Katana, Fraxtal. The raise token (WETH, frxUSD, etc.) varies by chain.

---

## Launch paths


|                       | EXPRESS       | ADVANCED                            |
| --------------------- | ------------- | ----------------------------------- |
| Presale duration      | 24 hours (default, configurable) | 2-14 days (default 7d) |
| Presale allocation    | Fixed 50%     | 25-50% (divisible by 5%)            |
| Start delay           | Immediate     | 24 hours                            |
| Vesting               | Not available | Up to 5 recipients (required if presale < 50%; referrer can be included) |
| Referrer              | Not available | Optional                            |
| Issuer fee recipients | 1             | Up to 4                             |
| Clones deployed       | 4             | 4-5 (VestingStream only if vesting) |


---

## Token allocation

Every launch mints exactly **10 billion tokens**, split as follows:


| Bucket                                | Formula                 | 50% Example (Express) | 30% Example (Advanced) |
| ------------------------------------- | ----------------------- | --------------------- | ---------------------- |
| Presale                               | supply * presalePercent | 5.0B                  | 3.0B                   |
| Liquidity (burned permanently)        | same as presale         | 5.0B                  | 3.0B                   |
| LP staking incentive                  | remainder * 20%         | 0                     | 0.8B                   |
| Issuer vesting (3yr linear, 7d cliff) | remainder - incentive   | 0                     | 3.2B                   |


Presale and liquidity are always equal. LP tokens are burned to a dead address for permanent liquidity.

---

## Presale

- Users contribute raise token during the presale window
- **Time-weighted bonus:** 10% bonus at start, decays linearly to 0% at end (early contributors get more tokens per unit)
- **Graduation threshold:** minimum raise required (set per chain). If not met, users can refund
- **Liquidity seeding:** anyone can trigger 1 hour after presale ends. Mints tokens, creates the DEX pair, burns LP tokens permanently
- **Token claims:** 7-day cliff after seeding, then immediately claimable

---

## Transfer tax

Every non-exempt transfer pays a **1.15% tax** (115 BPS at current defaults). The tax rate is the sum of the fee BPS components and is frozen per-launch at deployment. The admin can change defaults via timelock for future launches.

**Anti-whale protection:** For the first 90 minutes after launch, tax starts at 40% and decays linearly down to the base rate. This discourages sniping.

---

## Fee distribution

Tax fees are split differently depending on the factory deployment mode. Actual amounts depend on transfer volume and may be zero:

**Boardwalk-only mode:**


| Recipient            | BPS | How it works                                                          |
| -------------------- | --- | --------------------------------------------------------------------- |
| Issuer               | 40  | Claimable as raise token, rate-limited to 10% of accrued per 24 hours |
| Protocol (Boardwalk) | 45  | Accumulated, keeper batch-swaps to raise token                        |
| LP Staking           | 30  | Weekly epoch distributions for LP stakers                             |
| Referrer             | 5   | Carved from protocol share, claimable anytime                         |


**Integrator mode** (separate factory deployment):


| Recipient            | BPS | How it works                             |
| -------------------- | --- | ---------------------------------------- |
| Issuer               | 35  | Same claim mechanics                     |
| Protocol (Boardwalk) | 30  | Same swap mechanics                      |
| LP Staking           | 25  | Same epoch mechanics                     |
| Integrator           | 25  | Claimable in native token, no rate limit |


Integrator and referrer are mutually exclusive. The integrator address is permanent per-launch.

Collector migrations are atomic: switching the fee collector also rotates token tax exemptions in the same transaction (old collector removed, new collector added).

On **Base**, the protocol share is further split: **30% to treasury, 70% to GovernanceVoter** for weekly governance-directed allocation.

---

## LP staking

Stakers receive distributions from two sources:

1. **Vesting distribution:** 3-year linear release of the LP incentive allocation. Starts 24 hours after liquidity seeding.
2. **Fee epoch distribution:** Weekly distribution of the LP staking share of transfer taxes. Amounts depend on actual transfer volume and may be zero.

**Multiplier points:** Accrue at a fixed onchain rate of 1 MP per LP staked per year. MP increases a staker's effective weight without additional capital. MP burns proportionally on withdrawal.

**Zero-staker periods:** If nobody is staking during a period, those distributions are permanently lost (not carried forward).

---

## Vesting

Up to 5 named recipients receive tokens linearly over 3 years with a 7-day cliff after liquidity seeding. Claims are tax-exempt. Advanced path only. The referrer can optionally be included as a vesting recipient. The issuer can update recipient addresses via a 7-day timelock (vesting amounts and schedule remain immutable); execution auto-claims any vested-but-unclaimed tokens for the outgoing recipient. The issuer can also permanently burn the ability to change a specific recipient's address.

---

## BoostBurn (Community Ranking)

Any wallet burns BMX to boost or deboost any token's score. One interaction per (wallet, token) per epoch (30 days at planned deployment). Scores can go negative. BMX cost is timelocked-adjustable (0-1 BMX, default 0.1). Epoch duration is immutable once deployed. **NFT membership holders can boost/deboost for free** (100% discount by default, admin-adjustable).

---

## NFT Membership Discounts

Holders of the Boardwalk NFT membership receive fee discounts on LaunchFactory and BoostBurn. Both contracts inherit a shared `MembershipDiscount` base that checks ERC-721 `balanceOf > 0`. Each contract stores its own NFT collection address and discount BPS, both admin-adjustable via the standard 7-day timelock. Setting the NFT address to `address(0)` disables discounts entirely.

| Contract | Discount | Default |
|:---------|:---------|:--------|
| LaunchFactory | Reduced BMX burn for `createLaunch` | 25% off (2500 BPS) |
| BoostBurn | Reduced BMX cost for `boost`/`deboost` | Free (10000 BPS = 100% off) |

---

## Governance (Base Only)

The GovernanceVoter contract receives 70% of the protocol fee share and lets sbfBMX holders vote on how it's allocated each epoch (weekly at planned deployment; epoch duration is immutable once deployed). Allocation amounts depend on actual protocol activity, volume, and onchain conditions, and may be zero. Peer wiring is one-time via `initializePeers` after deploying GovernanceVoter, then LPLocker(voter), then ParticipationDistributor(voter).

### Weekly cycle

1. **Voting (epoch N):** sbfBMX holders vote on one of four options for **epoch N+1**. Vote weight = sbfBMX balance. Voting requires a 1.5% participation points threshold (participation points are non-transferable and have no monetary value). An optional BMX burn per vote is configurable (starts at 0).
2. **Finalization:** `finalize(N)` reads epoch `N-1` votes (epoch 0 defaults to treasury), re-validates voter balances in batches, and snapshots budget as `currentBalance - accountedBudget`. Finalization is sequential: epoch `N-1` must be finalized and executed before epoch `N`. Staking is temporarily disabled during tally. `finalize()` is keeper-or-owner.
3. **Execution:** `execute()` is keeper-or-owner and executes the finalized winner with slippage protection. Ineligible options (consecutive-win cap reached) are skipped during winner selection, and zero supply/zero vote-weight epochs fail quorum safely. If execution is stuck for 14+ days, anyone can force-mark the epoch as executed (budget goes to a separate **fallback treasury** -- not the regular treasury -- and `accountedBudget` is decremented).

### Vote options


| Option            | What happens                                                               |
| ----------------- | -------------------------------------------------------------------------- |
| 1. Treasury       | 100% of governance budget goes to treasury                                 |
| 2. Buy & Burn BMX | Swap to BMX via Uniswap, burn it                                           |
| 3. Buy & Burn LP  | Swap half to BMX via native ETH, mint Uniswap v4 LP position (ETH/BMX), lock permanently |
| 4. Participation  | Swap to BMX, stream to eligible voters over 7 days                         |


**Consecutive win cap:** An option winning 3 times in a row becomes ineligible for the next epoch.

**No quorum:** If quorum isn't met, the budget goes to treasury.

### Supporting contracts

- **LPLocker:** Holds Uniswap v4 LP position NFTs permanently (ETH/BMX pool, using native ETH). Trading fees are harvested by calling `PositionManager.modifyLiquidities()` directly (not Universal Router), and treasury is read dynamically from GovernanceVoter. Liquidity can never be withdrawn.
- **ParticipationDistributor:** When Option 4 wins, creates a 7-day linear BMX stream. Any voter from the prior epoch can claim their proportional share. `claimable()` returns both total allocation and currently claimable amount. `claimAll()` batch-claims across multiple epochs in one transaction.

All v4 interactions use native ETH (`address(0)`) — GovernanceVoter unwraps WETH before swaps and mints, sends ETH via `msg.value`, and uses SWEEP to recover excess. Action IDs are imported from `@uniswap/v4-periphery/src/libraries/Actions.sol`.

---

## Per-launch contracts (clones)


| Contract           | What it does                                                                                 |
| ------------------ | -------------------------------------------------------------------------------------------- |
| **BoardwalkToken** | ERC20 with embedded transfer tax and anti-whale decay. No owner/admin functions; feeCollector exemption rotation is feeDistributor-only. |
| **FeeDistributor** | Routes tax to LP staking, protocol, issuer, referrer/integrator. Timelocked address changes. |
| **PresaleManager** | Handles contributions, graduation, liquidity seeding, token claims, refunds. Immutable.      |
| **LPStaking**      | LP staking with vesting + fee epochs + multiplier points. Immutable.                         |
| **VestingStream**  | 3-year linear vesting with 7-day cliff. Issuer can update recipient addresses via 7-day timelock. Advanced path only. |


## Singleton contracts (shared)


| Contract                     | What it does                                                                            |
| ---------------------------- | --------------------------------------------------------------------------------------- |
| **LaunchFactory**            | Deploys and initializes all per-launch clones. Manages global config.                   |
| **BoardwalkFeeCollector**    | Aggregates protocol fees, keeper swaps to raise token, forwards to treasury/governance. |
| **BoardwalkLPManager**       | Tax-exempt wrapper for adding/removing LP, restricted to pairs including `RAISE_TOKEN`. |
| **BoostBurn**                | Community token ranking via BMX burn.                                                   |
| **GovernanceVoter**          | Weekly governance voting + advance-vote execution + vault (Base only; peers set via `initializePeers`). |
| **LPLocker**                 | Permanent v4 LP position lock with fee harvesting (Base only).                          |
| **ParticipationDistributor** | 7-day BMX streaming for governance Option 4 (Base only).                                |


---

## Admin functions and timelocks

All admin changes go through a generic `signalAction` / `cancelAction` API on the `Timelocked` base contract. Each contract provides an auth hook (`_authAdmin`) and an optional delay hook. Default delay is **7 days** with a 7-day expiry window; governance parameters use **21 days**. The owner signals the change, then anyone can execute it after the delay. The owner can cancel at any time before execution. Any timelocked action can be **permanently burned** (disabled forever) via a separate timelocked burn flow.

### LaunchFactory (Owner = Boardwalk multisig)


| What changes                    | Constraints                                                                        |
| ------------------------------- | ---------------------------------------------------------------------------------- |
| BMX burn amount                 | Max 200 BMX. Action can be permanently burned.                                    |
| Graduation threshold (Express)  | Must be > 0                                                                        |
| Graduation threshold (Advanced) | Must be > 0                                                                        |
| Express presale duration        | Must be > 0                                                                        |
| Advanced presale duration       | Must be 2-14 days                                                                  |
| Fee BPS defaults                | Per-component: issuer 10-80, boardwalk 10-50, incentive 0-50, referrer 0-10, integrator 0-50 |
| Presale range (min/max %)       | 500-5000 BPS, divisible by 500                                                     |
| Fee collector address           | Non-zero. Affects future launches only.                                            |
| Integrator address              | Timelocked. Affects future launches only.                                          |
| NFT collection address          | address(0) disables membership discounts.                                          |
| Member launch discount BPS      | 0-10000 BPS. 2500 = 25% off.                                                      |


### FeeDistributor (Per-launch, signaled by current recipient)


| What changes             | Who signals       | Constraints |
| ------------------------ | ----------------- | ----------- |
| Issuer recipient address | Current recipient | Non-zero    |
| Referrer address         | Current referrer  | Non-zero    |


### BoardwalkFeeCollector (Owner = Boardwalk multisig)


| What changes        | Constraints                                                                                                      |
| ------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Treasury address    | Non-zero                                                                                                         |
| Keeper address      | Non-zero                                                                                                         |
| Governance vault    | Can be zero (disables governance split)                                                                          |
| Collector migration | Batch-updates all FeeDistributor references. Both new address and distributor list are committed at signal time. |


### BoostBurn (Owner = Boardwalk multisig)


| What changes              | Constraints              |
| ------------------------- | ------------------------ |
| BMX cost                  | 0-1 BMX                  |
| NFT collection address    | address(0) disables      |
| Member boost discount BPS | 0-10000 BPS. 10000 = free |


### GovernanceVoter (Owner = Boardwalk multisig)


| What changes                   | Delay       | Constraints           |
| ------------------------------ | ----------- | --------------------- |
| Treasury address               | **7 days**  | Non-zero. Receives Option 1 / dust funds.  |
| Governance burn (BMX per vote) | **21 days** | 0-1 BMX               |
| Fallback treasury              | **21 days** | Non-zero. Receives forced-execution funds. |
| Keeper address                 | **7 days**  | Non-zero              |


### VestingStream (Per-launch, signaled by issuer)


| What changes               | Who signals    | Constraints                                                                 |
| -------------------------- | -------------- | --------------------------------------------------------------------------- |
| Vesting recipient address  | Launch issuer  | Non-zero. Execute auto-claims for outgoing recipient. Action can be permanently burned per allocation. |


### Contracts with no admin functions

These are fully immutable after initialization:

- BoardwalkToken (no owner/admin functions; exemption updates are feeDistributor-only)
- LPStaking
- PresaleManager
- BoardwalkLPManager
- LPLocker
- ParticipationDistributor

---


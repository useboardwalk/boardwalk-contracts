# Boardwalk Launchpad — Complete Technical Summary

## System Overview

Boardwalk Launchpad is a permissionless token launch protocol with embedded tax mechanisms, presale functionality, liquidity provision, and LP staking. The system uses EIP-1167 minimal proxy clones for gas-efficient deployment, allowing multiple token launches from single implementation contracts.

**Core Components:**
- **Presale System**: Collects raise token (WETH, frxUSD, or other standard ERC20 depending on deployment chain) contributions with time-weighted bonuses, graduates to liquidity seeding if threshold met
- **Tax Mechanism**: Universal transfer tax with anti-whale protection (40% decaying to base rate over 90 minutes)
- **Fee Distribution**: Automatic routing of transfer tax fees to LP staking, Boardwalk treasury, issuers, and referrers
- **LP Staking**: Continuous vesting distribution (3 years) plus weekly fee epochs with multiplier points (accruing at a fixed onchain rate of 100% per year)
- **Vesting**: Linear vesting for issuer allocations (7-day cliff, 3-year vesting)

**Two Launch Paths:**
- **EXPRESS**: 24-hour presale, 50% allocation, no vesting, no referrer, 1 issuer fee recipient
- **ADVANCED**: 7-day presale (default), 25-50% allocation (divisible by 5%), vesting required when presale < 50% (up to 5 recipients; referrer can be included), optional referrer, up to 4 issuer fee recipients

**Multi-Chain Deployment:** The system is designed for deployment across multiple chains (Ethereum, Base, Katana, Fraxtal). The raise token can be any standard ERC20 (WETH, frxUSD, vbUSDC, etc.) depending on the chain. Graduation thresholds are set per chain at deployment time.

---

## Contract Map

### 1. BoardwalkToken

**Purpose**: ERC20 token with universal embedded tax mechanism and anti-whale protection. Deployed as clone per launch.

**Type**: Clone (EIP-1167 minimal proxy)

**Inherits**: ERC20 (OpenZeppelin), Initializable (OpenZeppelin)

**Key State Variables:**
- `baseTaxBps`: Base tax rate in basis points (e.g., 115 = 1.15%)
- `liquiditySeedTime`: Timestamp when liquidity seeded
- `feeDistributor`: FeeDistributor clone address
- `presaleManager`: PresaleManager clone address (authorized to mint)
- `isExempt`: Mapping of tax-exempt addresses (mutable only via `updateExempt` by `feeDistributor`)

**Public/External Functions:**
- `initialize(...)`: Initialize clone with name, ticker, tax rate, addresses, exempt list (uses OZ `initializer` modifier, `_disableInitializers()` in constructor)
- `mint(to, amount)`: Only `presaleManager` can mint (enforces 10B supply cap)
- `setLiquiditySeedTime(seedTime)`: Only `presaleManager` can set (activates tax). Rejects zero (sentinel) and future timestamps.
- `updateExempt(account, exempt)`: Only `feeDistributor` can call (used for atomic fee collector migrations)
- `name()` / `symbol()`: Override ERC20 to return clone-specific values

**Admin Functions & Timelocks**: No owner/admin functions. Exemption updates are restricted to `feeDistributor` only (`updateExempt`) and used for collector migration safety. Emits `TokenInitialized` (custom event name to avoid conflict with OZ's `Initialized(uint64)`).

**Key Security Properties:**
1. **Tax Exemption Safety**: FeeDistributor MUST be exempt to prevent infinite recursion
2. **Supply Cap**: Hardcoded 10 billion total supply, enforced in `mint()`
3. **Anti-Whale Protection**: Tax starts at 40%, decays linearly to base rate over 90 minutes
4. **Zero Seed Time Rejection**: `setLiquiditySeedTime(0)` reverts with `ZeroSeedTime` to prevent resetting the sentinel

---

### 2. FeeDistributor

**Purpose**: Per-launch clone that routes transfer tax fees to multiple recipients (LP staking, Boardwalk, issuer, referrer). Receives tax via callback from BoardwalkToken.

**Type**: Clone

**Inherits**: Timelocked (7-day delay for address changes), Initializable (OpenZeppelin)

**Key State Variables:**
- `token`: BoardwalkToken address
- `lpStaking`: LPStaking contract address
- `feeCollector`: BoardwalkFeeCollector address (changeable via `setFeeCollector`)
- `router`: DEX router address (for issuer raise token claim swaps)
- `raiseToken`: Raise token address (WETH, frxUSD, or other standard ERC20)
- `issuerRecipients`: Array of issuer fee recipients (1-4)
- `referrer`: Referrer address (address(0) if none, timelocked changeable)
- `issuerClaimStates`: Per-recipient claim state (rate limiting)
- `referrerAccrued` / `referrerClaimed`: Referrer fee tracking
- `pendingLpFees` / `pendingBoardwalkFees`: Fallback accumulators for failed fee forwards

**Public/External Functions:**
- `initialize(...)`: Initialize with all addresses, BPS splits, recipients
- `onTaxReceived(amount)`: Only `token` can call. Splits fees and forwards with try/catch safety net. Failed forwards accumulate in `pendingLpFees` / `pendingBoardwalkFees`.
- `retryPendingFees()`: Public function to retry forwarding any accumulated failed fees. Anyone can call.
- `setFeeCollector(newFeeCollector)`: Only current `feeCollector` can call. Atomically rotates token exemption (`old=false`, `new=true`) and token approvals.
- `claimAsRaiseToken(recipientIdx, minRaiseTokenOut, deadline)`: Issuer claims fees as raise token (rate limited: 10% per 24h)
- `claimReferrerFees()`: Referrer claims accrued fees (no rate limit)
- `claimableAmount(recipientIdx)`: View function for claimable issuer fees (includes dust escape for sub-10-wei amounts)
- `signalChangeIssuerAddress(idx, newAddr)` / `executeChangeIssuerAddress(...)` / `cancelChangeIssuerAddress(...)`: Timelocked issuer address change
- `signalChangeReferrerAddress(...)` / `executeChangeReferrerAddress(...)` / `cancelChangeReferrerAddress(...)`: Timelocked referrer address change

**Admin Functions & Timelocks**: 
- All recipient address changes use 7-day delay + 7-day expiry
- Only current recipient can signal/cancel, anyone can execute after delay
- Zero-address validation performed in execute (not signal) for consistency
- `setFeeCollector` is authorized by the current FeeCollector contract (timelocked at the FeeCollector level)
- FeeDistributor inherits `Timelocked` but blocks the generic `signalAction` / `cancelAction` path: `_authAdmin` always reverts; only the typed issuer/referrer signal/cancel/execute flows apply

**Key Security Properties:**
1. **Rate Limiting**: Issuer claims limited to 10% of total accrued per 24-hour period
2. **Dust Escape**: When rate-limit rounds to zero (totalAccrued < 10 wei), full unclaimed amount is claimable
3. **Remainder Handling**: Last issuer recipient gets remainder to avoid rounding dust
4. **Transfer Resilience**: LP and boardwalk fee forwards use try/catch — if a downstream call reverts, fees accumulate internally and can be retried via `retryPendingFees()`. Token transfers never revert due to downstream issues.
5. **Atomic Collector Rotation**: `setFeeCollector` first rotates token exemptions (`updateExempt(old,false)` then `updateExempt(new,true)`), then revokes old approval and grants max approval to the new collector

---

### 3. LPStaking

**Purpose**: Immutable LP staking contract combining continuous vesting distribution (3 years) with weekly fee epochs. Uses accumulator pattern and multiplier points (fixed onchain accrual rate of 1 MP per LP token per year).

**Type**: Clone

**Inherits**: ReentrancyGuardTransient (EIP-1153 transient storage), Initializable (OpenZeppelin)

**Key State Variables:**
- `lpToken`: LP token address (Boardwalk DEX pair)
- `rewardToken`: BoardwalkToken address
- `vestingAllocation`: Total LP incentive tokens for 3-year vesting
- `vestingStart`: Timestamp when vesting starts (seedTime + 24h)
- `vestingEnd`: Timestamp when vesting ends (vestingStart + 3 years)
- `accRewardPerWeight`: Cumulative reward per unit of weight (1e30 precision)
- `totalWeight`: Total weight across all stakers (LP + MP)
- `currentEpochStart`: Current fee epoch start timestamp
- `currentEpochFees`: Fees being distributed in current epoch
- `pendingEpochFees`: Fees accumulating for next epoch
- `userInfo`: Per-user staking state (LP staked, MP, reward debt)

**Public/External Functions:**
- `setInitializer(addr)`: Factory calls once to lock initializer
- `initialize(...)`: Only `initAuthorizer` can call (sets vesting params, epoch start)
- `stake(amount)`: Stake LP tokens, auto-claims pending rewards
- `withdraw(amount)`: Withdraw LP tokens, burns MP proportionally, auto-claims
- `claim()`: Claim pending rewards without staking/withdrawing
- `notifyFees(amount)`: Only `feeDistributor` can call. Triggers `_updateAllRewards()` (epoch advancement if needed), then pulls tokens and increments `pendingEpochFees`. No reentrancy guard (both sender and receiver are tax-exempt). Wrapped in try/catch by `FeeDistributor.onTaxReceived`, so reverts here don't brick transfers.
- `pendingRewards(account)`: View function for pending rewards (simulates state)
- `getPoolStats()`: View function for pool statistics
- `getUserInfo(account)`: View function for user statistics (returns stakedLp, currentMp, effectiveWeight, pending, poolShareBps)

**Admin Functions & Timelocks**: None (zero admin functions, fully immutable)

**Key Security Properties:**
1. **Zero-Staker Loss**: Rewards are LOST during zero-staker periods (not carried over)
2. **MP Update Ordering**: Pending rewards calculated BEFORE MP update (prevents insolvency)
3. **Proportional MP Burn**: MP burned proportionally on withdrawal
4. **Reliable Epoch Advancement**: `notifyFees` triggers `_updateAllRewards()` on every taxed transfer (most reliable trigger). No `nonReentrant` needed — both sender (FeeDistributor) and receiver (LPStaking) are tax-exempt, eliminating reentrancy vectors. The caller's try/catch ensures this can't brick transfers.
5. **Lazy MP Evaluation Tradeoff**: MP accrual is lazily crystallized on user interactions (`stake`/`withdraw`/`claim`), so more active users crystallize MP sooner than inactive users (documented behavior).

---

### 4. PresaleManager

**Purpose**: Per-launch clone handling raise token contributions during presale, seeding permanent liquidity on graduation, and managing presale token claims after 7-day cliff.

**Type**: Clone

**Inherits**: Initializable (OpenZeppelin)

**Key State Variables:**
- `token`: BoardwalkToken clone address
- `feeDistributor`: FeeDistributor clone address
- `vestingStream`: VestingStream clone address (address(0) for Express)
- `lpStaking`: LPStaking clone address
- `raiseToken`: Raise token address (WETH, frxUSD, or other standard ERC20)
- `presaleStart` / `presaleEnd`: Presale timing
- `presalePercent`: Presale percentage in BPS (2500-5000)
- `graduationThreshold`: Minimum raise token for graduation
- `totalWethRaised`: Total raise token raised
- `totalWeightedWeth`: Total weighted raise token (for O(1) token calculation)
- `contributions`: Per-user contribution tracking (totalWeth, weightedWeth)
- `seeded`: Whether liquidity has been seeded

**Public/External Functions:**
- `initialize(...)`: Initialize with all addresses, duration, presale percent, threshold, delay flag
- `setVestingConfig(recipients, amounts)`: Only `factory` can call (sets vesting config)
- `contribute(amount)`: Public contribution during presale (calculates time-weighted bonus)
- `seedLiquidity()`: Public function callable after presale + 1 hour (mints tokens, creates LP, burns LP tokens)
- `claimTokens()`: Presale participants claim tokens after 7-day cliff
- `refund()`: Users refund raise token if presale fails (below threshold)
- `calculateTokens(account)`: View function for claimable tokens (O(1) gas)
- `hasFailed()`: View function for presale failure status
- `cliffEnd()`: View function for cliff end timestamp

**Admin Functions & Timelocks**: None (only `setVestingConfig` is factory-only, called once)

**Key Security Properties:**
1. **O(1) Gas**: Uses weighted raise token tracking for O(1) token calculation
2. **Time-Weighted Bonuses**: 10% bonus at start, decays linearly to 0% at end
3. **Public Liquidity Seeding**: Anyone can seed after delay (prevents griefing)
4. **LP Token Burning**: LP tokens burned to DEAD_ADDRESS (permanent liquidity)
5. **Router/Factory Coherence**: `initialize()` validates `IRouterFactory(router).factory() == dexFactory` to catch misconfiguration at init time

---

### 5. VestingStream

**Purpose**: Per-launch clone implementing linear vesting with 7-day cliff for issuer-directed token allocations. Supports up to 5 recipients. Allocation labels are emitted by LaunchFactory at creation time (not stored on-chain).

**Type**: Clone

**Inherits**: Timelocked, Initializable (OpenZeppelin)

**Key State Variables:**
- `token`: BoardwalkToken address
- `allocations`: Mapping of vesting allocations by index (0-4)
- `allocationCount`: Number of allocations (0-5)
- `cliffEnd`: Timestamp when cliff ends (seedTime + 7 days)
- `vestingEnd`: Timestamp when vesting ends (cliffEnd + 3 years)
- `issuer`: Launch issuer address, authorized for timelocked recipient changes

**Public/External Functions:**
- `setInitializer(addr, issuer)`: Factory calls once to lock initializer and set issuer
- `initialize(...)`: Only `initAuthorizer` can call (sets token, timing, allocations)
- `claim(allocationId)`: Recipient claims vested tokens (only after cliff ends)
- `signalAction(action, dataHash)`: Issuer signals recipient address change (inherited from Timelocked)
- `cancelAction(action)`: Issuer cancels pending change (inherited from Timelocked)
- `executeChangeRecipientAddress(allocationId, newAddress)`: Typed execute after 7-day delay (permissionless). Auto-claims any vested-but-unclaimed tokens for the outgoing recipient before switching.
- `signalBurnAction(action)` / `executeBurnAction(action)`: Issuer can permanently burn the ability to change a specific recipient
- `claimable(allocationId)`: View function for claimable amount
- `totalVested(allocationId)`: View function for total vested amount

**Admin Functions & Timelocks**: VestingStream inherits `Timelocked` with `_authAdmin` gating on the issuer. The issuer uses the generic `signalAction` / `cancelAction` path to signal and cancel recipient address changes. Only the typed `executeChangeRecipientAddress` performs the actual state mutation. The issuer can also permanently burn the change ability for specific allocations via `signalBurnAction` / `executeBurnAction`. Vesting amounts, schedule, and labels are fully immutable. Only recipient addresses are mutable via 7-day timelocked changes, controlled exclusively by the launch issuer.

**Key Security Properties:**
1. **Cliff Enforcement**: Claims blocked until 7-day cliff ends
2. **Linear Vesting**: Tokens vest linearly over 3 years after cliff
3. **Tax-Exempt**: Contract whitelisted in token's exempt list
4. **Issuer-Controlled Address Changes**: Only the issuer (launch creator) can signal/cancel recipient address changes; recipients cannot change their own vesting addresses

---

### 6. LaunchFactory

**Purpose**: Singleton factory contract deploying token launches via EIP-1167 clones. Handles BMX burn, config validation, clone deployment, and initialization of all per-launch contracts.

**Type**: Singleton

**Inherits**: Ownable2Step, Timelocked, MembershipDiscount

**Key State Variables:**
- `TOKEN_IMPL` / `FEE_DISTRIBUTOR_IMPL` / `PRESALE_IMPL` / `VESTING_IMPL` / `LP_STAKING_IMPL`: Implementation addresses (immutable)
- `BMX`: BMX token address (burned on launch)
- `RAISE_TOKEN`: Raise token address (WETH, frxUSD, or other standard ERC20 depending on deployment chain)
- `BOARDWALK_ROUTER` / `BOARDWALK_DEX_FACTORY`: DEX addresses (immutable)
- `BOARDWALK_LP_MANAGER`: LP manager address (immutable)
- `boardwalkFeeCollector`: Fee collector address (mutable, timelocked setter for future launches)
- `bmxBurnAmount`: BMX amount required to burn (default: 100e18, max: 200e18)
- `memberLaunchDiscountBps`: BPS discount on BMX burn for NFT members (0-10000, default: 2500 = 25% off)
- `nftCollection`: NFT collection address for membership check (inherited from MembershipDiscount; address(0) = disabled)
- `minPresalePercent` / `maxPresalePercent`: Admin-adjustable presale range (default: 2500-5000 BPS, admin range: 500-5000 BPS)
- `expressDuration` / `advancedDuration`: Presale durations
- `graduationExpress` / `graduationAdvanced`: Graduation thresholds (constructor parameters, set per chain at deployment)
- `currentFeeBps`: Fee BPS defaults (frozen per-launch at deployment)
- `launches`: Mapping of token address to LaunchInfo
- `allLaunches`: Array of all launched token addresses

**Public/External Functions:**
- `createLaunch(config)`: Public launch creation (validates config, burns BMX with member discount if applicable, deploys clones, initializes)
- `signalAction(action, dataHash)`: Generic signal for any timelocked action (inherited from Timelocked)
- `cancelAction(action)`: Generic cancel for any pending action (inherited from Timelocked)
- `executeSetBmxBurn(amount)`: Timelocked BMX burn change
- `executeSetGraduation(path, threshold)`: Timelocked graduation threshold change (dispatches to per-path action key)
- `executeSetDuration(path, duration)`: Timelocked presale duration change (dispatches to per-path action key)
- `executeSetFeeDefaults(defaults)`: Timelocked fee defaults change
- `executeSetPresaleRange(min, max)`: Timelocked presale range change
- `executeSetFeeCollector(addr)`: Timelocked fee collector change (for future launches)
- `executeSetIntegrator(addr)`: Timelocked integrator change (integrator factory mode; future launches only)
- `executeSetNftCollection(addr)`: Timelocked NFT collection address change (address(0) disables discounts)
- `executeSetMemberLaunchDiscount(bps)`: Timelocked member launch discount BPS change (max 10000)
- `signalBurnAction(action)` / `executeBurnAction(action)` / `cancelBurnAction(action)`: Per-action permanent burn (7-day delay). Burns make the target action permanently unusable.
- `launchCount()`: View function for total launches

**Events**: `LaunchCreated` (includes `issuerFeeLabels` and `vestingLabels` for indexer consumption), `BmxBurnAmountChanged`, `GraduationThresholdChanged(LaunchPath path, uint256 oldThreshold, uint256 newThreshold)`, `PresaleDurationChanged(LaunchPath path, uint256 oldDuration, uint256 newDuration)`, `FeeDefaultsChanged`, `PresaleRangeChanged`, `FeeCollectorChanged`, `NftCollectionChanged`, `MemberLaunchDiscountChanged`. Burn lifecycle events (`ActionBurnSignaled`, `ActionBurnExecuted`, `ActionBurnCanceled`) inherited from `Timelocked`.

**Admin Functions & Timelocks**: 
- All admin functions use 7-day delay + 7-day expiry
- Only owner can signal/cancel, anyone can execute after delay
- Zero-address and parameter validation performed in execute (not signal) for consistency
- Any timelocked action can be permanently burned via `signalBurnAction`/`executeBurnAction` (7-day delay, irreversible)

**Key Security Properties:**
1. **Initializer Locking**: Initializers locked immediately after clone deployment (prevents front-running)
2. **Path Separation**: EXPRESS and ADVANCED have distinct validation rules
3. **Vesting Validation**: Advanced launches with `presalePercent < 5000` must provide vesting recipients (prevents under-minting issuer allocation)
4. **BMX Burn**: Prevents spam launches (max 200 BMX, can be permanently locked via per-action burn)
5. **Fee Model**: Referrer fees carved from boardwalk (not additive)
6. **Tightened Admin Bounds**: Fee defaults enforce per-component ranges (issuer 10-80, boardwalk 10-50, incentive 0-50, referrer 0-10, total max 190 BPS). BMX burn capped at 200e18.
7. **Presale Range Admin**: `minPresalePercent` / `maxPresalePercent` adjustable via timelock within 500-5000 BPS, divisible by 500
8. **Error Consolidation**: `TooManyVestingRecipients` + `TooManyFeeRecipients` merged into `TooManyRecipients`; `InvalidFeeSplitsSum` + `VestingPercentsMismatch` merged into `InvalidSplitsSum`

---

### 7. BoardwalkLPManager

**Purpose**: Singleton contract providing tax-exempt wrapper for adding/removing liquidity on Boardwalk DEX. Whitelisted on all tokens.

**Type**: Singleton

**Inherits**: None

**Key State Variables:**
- `FACTORY`: Boardwalk DEX factory address (immutable)
- `ROUTER`: Boardwalk DEX router address (immutable)
- `RAISE_TOKEN`: Raise token address (immutable)

**Public/External Functions:**
- `addLiquidity(...)`: Tax-free add liquidity (user → LPManager → Pair), restricted to pairs where tokenA or tokenB is `RAISE_TOKEN`
- `removeLiquidity(...)`: Tax-free remove liquidity (Pair → LPManager → User), restricted to pairs where tokenA or tokenB is `RAISE_TOKEN`

**Admin Functions & Timelocks**: None (fully immutable after deployment)

**Key Security Properties:**
1. **Tax-Exempt Operations**: Contract whitelisted in all token exempt lists
2. **Factory-Router Validation**: Constructor validates pairing
3. **Raise-Token Pair Restriction**: Blocks liquidity operations for arbitrary token-token pairs (prevents tax-free transfer tunnels)

---

### 8. BoardwalkFeeCollector

**Purpose**: Singleton contract aggregating Boardwalk's fee share from all FeeDistributors. Allows keeper to batch-swap accumulated tokens to raise token and auto-forwards to treasury. Tax-exempt on all Boardwalk tokens.

**Type**: Singleton

**Inherits**: Ownable2Step, Timelocked

**Key State Variables:**
- `RAISE_TOKEN`: Raise token address (immutable; WETH, frxUSD, or other standard ERC20 depending on deployment chain)
- `ROUTER`: Router address (immutable)
- `treasury`: Treasury address (receives raise token, timelocked changeable)
- `keeper`: Keeper address (can call swapToRaiseToken, timelocked changeable)
- `accumulatedFees`: Mapping of token to accumulated fees (for monitoring)

**Public/External Functions:**
- `receiveFees(token, amount)`: Public (called by FeeDistributors to deposit fees)
- `swapToRaiseToken(tokens[], minAmountsOut[])`: Only `keeper` can call (batch-swaps tokens to raise token via regular `swapExactTokensForTokens`)
- `signalAction(action, dataHash)` / `cancelAction(action)`: Generic timelock signal/cancel (inherited from Timelocked; owner via `_authAdmin`)
- `executeSetTreasury(addr)`: Timelocked treasury change
- `executeSetKeeper(addr)`: Timelocked keeper change
- `executeSetGovernanceVault(addr)`: Timelocked governance vault change
- `executeMigrateCollector(newCollector, distributors[])`: Timelocked collector migration (batch-updates FeeDistributor clones)
- `signalBurnAction` / `executeBurnAction` / `cancelBurnAction`: Per-action permanent burn (inherited from Timelocked)

**Admin Functions & Timelocks**: 
- Treasury, keeper, and migration changes use 7-day delay + 7-day expiry
- Only owner can signal/cancel, anyone can execute after delay
- Migration commits both `newCollector` AND `distributors[]` in signal hash (prevents griefing via incomplete execution)

**Key Security Properties:**
1. **Tax-Exempt**: Added to every token's exempt list at launch time. Uses standard `swapExactTokensForTokens` (not FOT variant).
2. **Batch Processing**: Supports batch swaps to reduce gas costs
3. **Collector Migration**: Timelocked batch migration of FeeDistributor references with committed distributor set

---

### 9. Timelocked

**Purpose**: Abstract base contract providing inline signal/execute timelock pattern with 7-day delay and 7-day expiry window.

**Type**: Base Contract (abstract)

**Inherits**: None

**Key State Variables:**
- `pendingChanges`: Mapping of action keys to pending changes (dataHash, signalTime, delay)
- `burnedActions`: Mapping of action keys to permanent burn status

**Virtual hooks (override in inheritors):**
- `_authAdmin(bytes32 action)`: Authorization for signal/cancel/burn-signal/burn-cancel; owner-controlled contracts implement as `onlyOwner`
- `_actionDelay(bytes32 action)`: Optional per-action delay for `signalAction` (default 7 days)
- `_burnDelay(bytes32 action)`: Optional per-action delay for `signalBurnAction` (defaults to `_actionDelay(action)`)

**Internal Functions:**
- `_signal(action, dataHash)` / `_signal(action, dataHash, delay)`: Signals pending change (overwrites existing). Reverts if action is burned.
- `_execute(action, dataHash)`: Executes pending change after delay (validates dataHash, timing). Reverts if action is burned.
- `_cancel(action)`: Cancels pending change
- `_signalBurn(action)` / `_signalBurn(action, delay)`: Signals permanent burn of a timelocked action (7-day default, custom delay for governance)
- `_executeBurn(action)`: Executes burn (sets `burnedActions[action] = true`, clears any pending change for that action). Irreversible.
- `_cancelBurn(action)`: Cancels a pending burn signal

**Public/External Functions:**
- `signalAction(action, dataHash)`: Wraps `_signal` with `_authAdmin` and `_actionDelay`
- `cancelAction(action)`: Wraps `_cancel` with `_authAdmin`
- `signalBurnAction(action)`: Wraps `_signalBurn` with `_authAdmin` and `_burnDelay`
- `executeBurnAction(action)`: Permissionless after delay (wraps `_executeBurn`)
- `cancelBurnAction(action)`: Wraps `_cancelBurn` with `_authAdmin`
- `getPendingChange(action)`: View function for pending change status and timing
- `isActionBurned(action)`: View function for burn status

**Admin Functions & Timelocks**: Typed `execute*` functions on each contract call `_execute` after the delay. FeeDistributor inherits this base but blocks the generic entry points by reverting in `_authAdmin`; it keeps its own typed issuer/referrer signal/cancel functions and does not expose burns (recipient-controlled actions are self-sovereign).

**Key Security Properties:**
1. **Delay Protection**: 7-day default delay prevents immediate execution (21-day for governance actions)
2. **Expiry Window**: 7-day expiry prevents stale changes
3. **Data Hash Verification**: Parameters verified via hash (prevents tampering)
4. **Per-Action Burn**: Once burned, an action can never be signaled or executed again. Burns are timelocked and cancellable before execution.

---

### 10. MembershipDiscount

**Purpose**: Abstract base contract providing shared NFT membership check and BPS discount helpers. Inherited by contracts that offer fee discounts to ERC-721 NFT holders (currently LaunchFactory and BoostBurn).

**Type**: Base Contract (abstract)

**Inherits**: None

**Key State Variables:**
- `nftCollection`: ERC-721 NFT contract address; `address(0)` = discounts disabled
- `ACTION_SET_NFT_COLLECTION`: Shared action key constant for timelocked setter

**Internal Functions:**
- `_isMember(account)`: Returns `true` when `account` holds at least one NFT; returns `false` when `nftCollection == address(0)`
- `_effectiveCost(baseCost, discountBps, account)`: Returns `baseCost - (baseCost * discountBps / 10000)` for members, `baseCost` for non-members
- `_setNftCollection(addr)`: Internal setter, emits `NftCollectionChanged`

**Key Security Properties:**
1. **Graceful Disable**: `address(0)` nftCollection returns `false` for all membership checks (no external call)
2. **No Timelocked Logic**: Consuming contracts wire timelocked setters using their own `Timelocked` infrastructure
3. **BPS-Based**: Consistent with BPS usage throughout the codebase; max 10000 (100% discount)

---

## Launch Paths

### EXPRESS Path

**Characteristics:**
- **Presale Duration**: 24 hours (configurable via admin, default: 24h)
- **Presale Allocation**: Fixed at 50% (5000 BPS)
- **Vesting**: Not allowed
- **Referrer**: Not allowed (must be address(0))
- **Issuer Fee Recipients**: Exactly 1
- **Start Delay**: None (starts immediately)

**Use Case**: Quick launches with minimal configuration, no vesting, no referrers.

**Token Allocation Example (50% presale):**
```
presaleTokens = 10B * 5000 / 10000 = 5B tokens
liquidityTokens = 10B * 5000 / 10000 = 5B tokens
vestingTotal = 10B - 5B - 5B = 0 tokens
lpIncentiveTokens = 0 tokens
issuerVestingTokens = 0 tokens
```

---

### ADVANCED Path

**Characteristics:**
- **Presale Duration**: 7 days (configurable via admin, default: 7d, range: 2-14 days)
- **Presale Allocation**: 25-50% (2500-5000 BPS), must be divisible by 5% (500 BPS)
- **Vesting**: Up to 5 recipients (referrer can be included). Required when `presalePercent < 50%` (to prevent under-minting)
- **Referrer**: Optional (address(0) = no referrer; can also be a vesting recipient)
- **Issuer Fee Recipients**: 1-4 recipients
- **Start Delay**: 24 hours before presale starts

**Use Case**: Full-featured launches with vesting, referrers, multiple fee recipients.

**Token Allocation Example (30% presale):**
```
presaleTokens = 10B * 3000 / 10000 = 3B tokens
liquidityTokens = 10B * 3000 / 10000 = 3B tokens
vestingTotal = 10B - 3B - 3B = 4B tokens
lpIncentiveTokens = 4B * 20 / 100 = 800M tokens
issuerVestingTokens = 4B - 800M = 3.2B tokens
```

---

## Fee Model

### Base Tax Rate

- **Default**: 1.15% (115 basis points)
- **Configurable**: Set per-launch at deployment (frozen after initialization)
- **Anti-Whale Decay**: Starts at 40% (4000 BPS), decays linearly to base rate over 90 minutes

**Tax Rate Formula:**
- **Before seed**: 0%
- **During anti-whale (0-90 min)**: `currentTax = 4000 - (4000 - baseTaxBps) * elapsed / 90 minutes`
- **After anti-whale**: `baseTaxBps`

---

### Fee Split (Boardwalk-Only Factory)

**Total Tax**: 1.15% (115 BPS)

| Recipient | BPS | Percentage |
|-----------|-----|------------|
| Issuer | 40 | 0.40% |
| Boardwalk | 45 | 0.45% |
| LP Incentive | 30 | 0.30% |
| Referrer | 5 | 0.05% |
| **Total** | **115** | **1.15%** |

**Referrer Carve-Out**: Referrer fees are carved from boardwalk (not additive):
- `boardwalkEffective = currentFeeBps.boardwalk - currentFeeBps.referrer`
- Total tax remains 1.15%

---

### Fee Split (Integrator Factory)

**Total Tax**: 1.15% (115 BPS)

| Recipient | BPS | Percentage |
|-----------|-----|------------|
| Issuer | 35 | 0.35% |
| Boardwalk | 30 | 0.30% |
| LP Incentive | 25 | 0.25% |
| Integrator | 25 | 0.25% |
| **Total** | **115** | **1.15%** |

---

### Issuer Claim Rate Limiting

- **Rate Limit**: 10% of total accrued per 24-hour period
- **Per-Recipient**: Each issuer recipient has independent rate limit
- **Period Reset**: Resets every 24 hours from `lastClaimTime`
- **Claim Method**: Issuers claim as raise token via swap (FeeDistributor is exempt, uses regular swap)

**Formula:**
```
unclaimed = totalAccrued - totalClaimed
if unclaimed == 0 → return 0

maxClaimable = totalAccrued / 10
if maxClaimable == 0 → return unclaimed   // dust escape: bypass rate limit for sub-10-wei amounts

remainingInPeriod = maxClaimable - claimedInCurrentPeriod
claimable = min(remainingInPeriod, unclaimed)
```

---

### Keeper Batch Swap Flow

1. **Fee Accumulation**: FeeDistributors call `FeeCollector.receiveFees(token, amount)` → tokens accumulate
2. **Keeper Triggers**: Keeper calls `FeeCollector.swapToRaiseToken(tokens[], minAmountsOut[])`
3. **Batch Swap**: For each token:
   - Get balance: `balance = IERC20(token).balanceOf(address(this))`
   - Approve router (max-approval pattern): if `allowance < balance`, `forceApprove(ROUTER, type(uint256).max)` — set once per token, skipped on subsequent runs
   - Swap: `ROUTER.swapExactTokensForTokens(...)` (standard swap with exact return values)
   - Read output: `raiseTokenReceived = amounts[amounts.length - 1]`
   - Clear tracking: `accumulatedFees[token] = 0`
4. **Auto-Forward**: All raise token forwarded to treasury in single transfer

**Note**: FeeCollector **IS tax-exempt** on all Boardwalk tokens (added to exempt list at launch time). Uses standard swap — no FOT variant or balance reconciliation needed.

---

## Token Allocation

### Allocation Formulas

**Constants:**
- `TOTAL_SUPPLY = 10,000,000,000e18` (10 billion tokens)
- `presalePercent`: Presale percentage in BPS (2500-5000)

**Formulas** (implemented in `AllocationLib.compute()`, shared by LaunchFactory and PresaleManager):
```
presaleTokens = TOTAL_SUPPLY * presalePercent / BPS_DENOMINATOR
liquidityTokens = presaleTokens
vestingTotal = TOTAL_SUPPLY - presaleTokens - liquidityTokens
lpIncentiveTokens = vestingTotal * LP_INCENTIVE_PERCENT / 100    // LP_INCENTIVE_PERCENT = 20
issuerVestingTokens = vestingTotal - lpIncentiveTokens
```

**Verification:**
```
presaleTokens + liquidityTokens + lpIncentiveTokens + issuerVestingTokens = TOTAL_SUPPLY
```

---

### Example: Express Path (50%)

**Inputs:**
- `presalePercent = 5000` (50%)

**Calculations:**
```
presaleTokens = 10B * 5000 / 10000 = 5,000,000,000e18
liquidityTokens = 10B * 5000 / 10000 = 5,000,000,000e18
vestingTotal = 10B - 5B - 5B = 0
lpIncentiveTokens = 0
issuerVestingTokens = 0
```

**Summary:**
- Presale: 5B tokens (50%)
- Liquidity: 5B tokens (50%)
- LP Incentive: 0 tokens (0%)
- Issuer Vesting: 0 tokens (0%)
- **Total: 10B tokens (100%)**

---

### Example: Advanced Path (30%)

**Inputs:**
- `presalePercent = 3000` (30%)

**Calculations:**
```
presaleTokens = 10B * 3000 / 10000 = 3,000,000,000e18
liquidityTokens = 10B * 3000 / 10000 = 3,000,000,000e18
vestingTotal = 10B - 3B - 3B = 4,000,000,000e18
lpIncentiveTokens = 4B * 20 / 100 = 800,000,000e18
issuerVestingTokens = 4B - 800M = 3,200,000,000e18
```

**Summary:**
- Presale: 3B tokens (30%)
- Liquidity: 3B tokens (30%)
- LP Incentive: 800M tokens (8%)
- Issuer Vesting: 3.2B tokens (32%)
- **Total: 10B tokens (100%)**

---

### Presale Token Distribution

**Per-User Calculation:**
```
userTokenAmount = user.weightedWeth * presaleTokens / totalWeightedWeth
```

**Weighted raise token:**
- Each contribution has bonus multiplier based on timing
- `weightedWeth = amount * bonusMultiplier / 10000`
- Bonus multiplier: Starts at 11000 (10% bonus) at presale start, decays linearly to 10000 (0% bonus) at end

**Example:**
- User contributes 10 raise token at start (bonusMultiplier = 11000)
- `weightedWeth = 10 * 11000 / 10000 = 11`
- If `totalWeightedWeth = 1000` and `presaleTokens = 3B`:
- `userTokenAmount = 11 * 3B / 1000 = 33M tokens`

---

## Staking Rewards

### Vesting Distribution (Continuous, 3-Year)

**Parameters:**
- **Duration**: 3 years (VESTING_DURATION = 3 * 365 days)
- **Start**: 24 hours after liquidity seed (VESTING_DELAY = 24 hours)
- **Rate**: `baseVestingRate = vestingAllocation / VESTING_DURATION` (tokens per second)
- **Distribution**: Linear over time, clamped to `[vestingStart, vestingEnd]`

**Formula:**
```
vestingReward = (elapsed) * baseVestingRate
accRewardPerWeight += vestingReward * PRECISION / totalWeight
```

**Key Property**: Rewards are **LOST** during zero-staker periods (not carried over).

---

### Fee Distribution (Weekly Epochs)

**Parameters:**
- **Epoch Duration**: 7 days (EPOCH_DURATION = 7 days)
- **Distribution**: Linear within each epoch
- **Rate**: `feeRewardRate = currentEpochFees / EPOCH_DURATION` (tokens per second)

**Epoch Lifecycle:**
1. Fees arrive via `notifyFees()` → triggers `_updateAllRewards()` (advances epoch if needed) → accumulates in `pendingEpochFees`
2. When epoch ends (7 days from `currentEpochStart`), the next `notifyFees` call or user action (stake/withdraw/claim) triggers advance:
   - `pendingEpochFees` → `currentEpochFees`
   - `feeRewardRate = currentEpochFees / EPOCH_DURATION`
   - `currentEpochStart = block.timestamp` (anchored to trigger time)
3. During active epoch: `accRewardPerWeight += (elapsed * feeRewardRate) * PRECISION / totalWeight`

**Key Property**: Rewards are **LOST** during zero-staker periods (not carried over).

---

### Multiplier points

**Accrual rate**: Fixed onchain rate of 1 MP per LP token per year

**Formula:**
```
newMP = lpStaked * elapsed / 365 days
```

**Examples:**
- 1000 LP staked for 1 year = 1000 MP
- 1000 LP staked for 6 months = 500 MP
- 1000 LP staked for 1 day = ~2.74 MP

**MP Burn**: On withdrawal, MP burned proportionally:
```
mpToBurn = multiplierPoints * amount / lpStaked
```

**Weight Calculation**: User's effective weight = LP staked + MP

---

### Zero-Staker Reward Loss

**Critical Behavior**: If `totalWeight == 0` during reward distribution:
- All vesting rewards for that period are **LOST**
- All fee rewards for that period are **LOST**
- `lastRewardUpdate` is updated, but no rewards are distributed

**Rationale**: Prevents accumulation of unclaimed rewards. Only stakers during a period receive rewards for that period.

**Implications**:
- If no one stakes during vesting period, vesting tokens are permanently lost
- If no one stakes during fee epoch, fee tokens are permanently lost
- Stakers must be active to receive rewards

---

## Timelocked Admin Functions (Complete List)

All timelocked functions use 7-day delay + 7-day expiry window unless noted. GovernanceVoter uses 21-day delay for governance-sensitive actions. Only owner/current recipient can signal, anyone can execute after delay.

**Cancel pattern:** LaunchFactory, BoardwalkFeeCollector, BoostBurn, and GovernanceVoter use `cancelAction(bytes32 action)` (inherited from Timelocked; owner only via `_authAdmin`) for any ACTION_* key. FeeDistributor uses per-action cancel functions since each has different access control (only the current recipient/referrer can cancel their own pending change).

**Per-action burn:** All owner-controlled contracts (LaunchFactory, BoardwalkFeeCollector, BoostBurn, GovernanceVoter) expose `signalBurnAction(action)` / `executeBurnAction(action)` / `cancelBurnAction(action)`. Burning permanently disables the target action. Burn delay matches the action's delay (7d default, 21d for governance actions). FeeDistributor does not support burns (recipient-controlled actions).

### LaunchFactory

Signaling uses `signalAction(action, dataHash)` (and `cancelAction(action)` to cancel); `action` is the constant in the Action Key column. `dataHash` must match what each typed `execute*` passes into `_execute` (typically `keccak256(abi.encode(...))` of the setter arguments).

| Function | Action Key | Who Signals | What Changes | Constraints |
|----------|-----------|-------------|--------------|-------------|
| `executeSetBmxBurn` | `SET_BMX_BURN` | Owner | `bmxBurnAmount` | Max 200e18 (200 BMX) |
| `signalBurnAction` / `executeBurnAction` / `cancelBurnAction` | Any ACTION_* key | Owner | Permanently disables the target action | Action must not already be burned |
| `executeSetGraduation(path, threshold)` | `SET_GRADUATION_EXPRESS` / `SET_GRADUATION_ADVANCED` | Owner | `graduationExpress` or `graduationAdvanced` | None / None |
| `executeSetDuration(path, duration)` | `SET_EXPRESS_DURATION` / `SET_ADVANCED_DURATION` | Owner | `expressDuration` or `advancedDuration` | Must be > 0 / Must be 2-14 days |
| `executeSetFeeDefaults` | `SET_FEE_DEFAULTS` | Owner | `currentFeeBps` (future launches only) | Per-component: issuer 10-80, boardwalk 10-50, incentive 0-50, referrer 0-10, total ≤ 190, referrer ≤ boardwalk |
| `executeSetPresaleRange` | `SET_PRESALE_RANGE` | Owner | `minPresalePercent`, `maxPresalePercent` | Min ≥ 500, max ≤ 5000, min ≤ max, divisible by 500 |
| `executeSetFeeCollector` | `SET_FEE_COLLECTOR` | Owner | `boardwalkFeeCollector` (future launches only) | Non-zero address (validated in execute) |
| `executeSetIntegrator` | `SET_INTEGRATOR` | Owner | `integrator` (integrator factory; future launches only) | Non-zero address (validated in execute) |
| `executeSetNftCollection` | `SET_NFT_COLLECTION` | Owner | `nftCollection` | address(0) disables membership discounts |
| `executeSetMemberLaunchDiscount` | `SET_MEMBER_LAUNCH_DISCOUNT` | Owner | `memberLaunchDiscountBps` | Max 10000 BPS |
| `cancelAction(action)` | Any of the above | Owner | Cancels the pending change | Inherited from Timelocked |

---

### FeeDistributor

| Function | Action Key | Who Signals/Cancels | What Changes | Constraints |
|----------|-----------|-------------|--------------|-------------|
| `signalChangeIssuerAddress` / `executeChangeIssuerAddress` / `cancelChangeIssuerAddress` | `keccak256(CHANGE_ISSUER, idx)` | Current recipient at idx | `issuerRecipients[idx]` | New address must be non-zero (validated in execute) |
| `signalChangeReferrerAddress` / `executeChangeReferrerAddress` / `cancelChangeReferrerAddress` | `CHANGE_REFERRER` | Current `referrer` | `referrer` | New address must be non-zero (validated in execute) |

---

### BoardwalkFeeCollector

Signaling uses `signalAction(action, dataHash)` (and `cancelAction(action)` to cancel); `action` is the constant in the Action Key column.

| Function | Action Key | Who Signals | What Changes | Constraints |
|----------|-----------|-------------|--------------|-------------|
| `executeSetTreasury` | `SET_TREASURY` | Owner | `treasury` | New address must be non-zero (validated in execute) |
| `executeSetKeeper` | `SET_KEEPER` | Owner | `keeper` | New address must be non-zero (validated in execute) |
| `executeSetGovernanceVault` | `SET_GOVERNANCE_VAULT` | Owner | Governance vault address | New address must be non-zero (validated in execute) |
| `executeMigrateCollector` | `MIGRATE_COLLECTOR` | Owner | Calls `setFeeCollector` on each FeeDistributor | Non-zero newCollector. Both newCollector AND distributors[] committed in signal hash. |
| `cancelAction(action)` | Any of the above | Owner | Cancels the pending change | Inherited from Timelocked |

---

### VestingStream

| Function | Action Key | Who Signals/Cancels | What Changes | Constraints |
|----------|-----------|-------------|--------------|-------------|
| `signalAction` / `executeChangeRecipientAddress` / `cancelAction` | `keccak256(CHANGE_RECIPIENT, allocationId)` | Issuer (launch creator) | `allocations[allocationId].recipient` | Non-zero. Execute auto-claims vested tokens for outgoing recipient. Action can be permanently burned. |

---

### Contracts with NO Admin Functions

- **BoardwalkToken**: No owner/admin functions; exemption list is mutable only by `feeDistributor` via `updateExempt`
- **LPStaking**: Fully immutable after initialization (zero admin)
- **PresaleManager**: Factory-only `setVestingConfig`, no ongoing admin
- **BoardwalkLPManager**: Immutable constructor params, no admin

---

## Cross-Contract Flows

### 1. Launch Creation

**Entry Point**: `LaunchFactory.createLaunch(LaunchConfig)`

**Flow:**
1. **BMX Burn**: Transfer BMX from issuer to DEAD_ADDRESS (if `bmxBurnAmount > 0`; NFT members pay discounted amount via `_effectiveCost`)
2. **Clone Deployment**: Deploy all clones (token, feeDistributor, presale, lpStaking, vesting if applicable)
3. **Initializer Locking**: Lock LPStaking and VestingStream initializers (prevents front-running)
4. **Token Initialization**: Initialize token with name, ticker, tax rate, feeDistributor, presale, exempt list (6 entries: presale, vesting, lpStaking, feeDistributor, lpManager, feeCollector)
5. **FeeDistributor Initialization**: Initialize with all addresses, BPS splits, recipients (referrer carve-out handled)
6. **PresaleManager Initialization**: Initialize with duration, presale percent, threshold, delay flag
7. **Vesting Config**: If applicable, call `PresaleManager.setVestingConfig()` with recipients and amounts
8. **Launch Registration**: Store LaunchInfo, emit LaunchCreated event

**Key Invariant**: All clones deployed before any initialization. Initialization order matters.

---

### 2. Presale → Liquidity Seeding

**Entry Point**: `PresaleManager.seedLiquidity()` (public, callable after presale + 1 hour)

**Preconditions:**
- `block.timestamp >= presaleEnd + SEED_DELAY` (1 hour)
- `!seeded`
- `totalWethRaised >= graduationThreshold`

**Flow:**
1. **Token Allocation Math**: `AllocationLib.compute(TOTAL_SUPPLY, presalePercent)` returns presaleTokens, liquidityTokens, lpIncentiveTokens, issuerVestingTokens
2. **Minting**: 
   - Mint `presaleTokens + liquidityTokens` to PresaleManager
   - Mint `lpIncentiveTokens` to LPStaking
   - Mint `issuerVestingTokens` to VestingStream (if applicable)
3. **LP Creation**: Transfer tokens and raise token directly to pair, call `pair.mint()` (direct minting, no router)
4. **LP Burn**: Transfer LP tokens to DEAD_ADDRESS (permanent liquidity)
5. **LPStaking Initialization**: Call `lpStaking.initialize()` with pair, token, feeDistributor, seedTime, allocation
6. **VestingStream Initialization**: If applicable, call `vestingStream.initialize()` with token, seedTime, recipients, amounts
7. **Anti-Whale Activation**: Call `token.setLiquiditySeedTime(seedTime)` (starts tax decay)

---

### 3. Tax → Fee Distribution

**Trigger**: Any non-exempt token transfer

**Flow:**
1. **Tax Calculation** (BoardwalkToken._update):
   - Check exemptions (from/to exempt → no tax)
   - Check seed time (not seeded → no tax = not minted)
   - Calculate tax: During anti-whale (decay), after anti-whale (base rate)
2. **Tax Transfer**: Send tax tokens to FeeDistributor (FeeDistributor is exempt → no recursive tax)
3. **Callback**: Call `FeeDistributor.onTaxReceived(tax)`
4. **Fee Splitting**: Calculate lpShare, boardwalkShare, referrerShare, issuerShare (proportional by BPS)
5. **LP Fee Forwarding** (try/catch): Call `LPStaking.notifyFees(lpShare)` → tokens go to `pendingEpochFees`. On failure: `pendingLpFees += lpShare`, emit `FeeForwardFailed`.
6. **Boardwalk Fee Forwarding** (try/catch): Call `FeeCollector.receiveFees(token, boardwalkShare)` → tokens accumulate. On failure: `pendingBoardwalkFees += boardwalkShare`, emit `FeeForwardFailed`.
7. **Issuer Fee Accrual**: Call `_accrueIssuerFees(issuerShare)` → distribute to recipients by splits (last gets remainder). Storage-only, can't fail.
8. **Referrer Fee Accrual**: Increment `referrerAccrued += referrerShare`. Storage-only, can't fail.
9. **Fee Retry** (if needed): Anyone can call `retryPendingFees()` to flush accumulated failed fees.

---

### 4. LP Staking Lifecycle

**Stake Flow:**
1. User calls `LPStaking.stake(amount)`
2. Update all rewards: `_updateAllRewards()` (advances epoch if needed, distributes rewards)
3. Settle pending rewards with OLD weight (before MP update)
4. Update MP: `_updateUserMp(user)` (accrues MP based on elapsed time)
5. Transfer LP tokens in: `lpToken.safeTransferFrom(user, contract, amount)`
6. Update weight: Increment `user.lpStaked`, update `totalWeight`, set new `rewardDebt`

**Withdraw Flow:**
1. User calls `LPStaking.withdraw(amount)`
2. Update all rewards: `_updateAllRewards()`
3. Settle pending rewards with OLD weight (before MP update)
4. Update MP: `_updateUserMp(user)`
5. Calculate proportional MP burn: `mpToBurn = user.multiplierPoints * amount / user.lpStaked`
6. Update weight: Decrement `user.lpStaked`, decrement `user.multiplierPoints`, update `totalWeight`, set new `rewardDebt`
7. Transfer LP tokens out: `lpToken.safeTransfer(user, amount)`

**Claim Flow:**
1. User calls `LPStaking.claim()`
2. Update all rewards: `_updateAllRewards()`
3. Calculate pending with STORED weight (before MP update)
4. Transfer tokens: `rewardToken.safeTransfer(user, pendingAmount)`
5. Update MP: `_updateUserMp(user)` (for future calculations)
6. Recalculate debt with new weight

---

## Tax Exemptions

Every BoardwalkToken has these addresses exempt from tax (set at initialization, immutable):

| Address | Reason |
|---------|--------|
| FeeDistributor | Prevents recursive tax during `onTaxReceived` callback |
| PresaleManager | Token claims after cliff are tax-free |
| VestingStream | Vesting claims are tax-free |
| LPStaking | Reward claims and fee forwarding are tax-free |
| BoardwalkLPManager | LP add/remove operations are tax-free |
| BoardwalkFeeCollector | Keeper swaps are tax-free (uses standard swap, no FOT variant) |

---

## Clone vs Singleton

### Per-Launch Clones (5 contracts per launch)

| Contract | Cloned From | Initialized By | Initializer Lock |
|----------|------------|----------------|-----------------|
| BoardwalkToken | `TOKEN_IMPL` | LaunchFactory | OZ `initializer` modifier, `_disableInitializers()` in constructor |
| FeeDistributor | `FEE_DISTRIBUTOR_IMPL` | LaunchFactory | OZ `initializer` modifier, `_disableInitializers()` in constructor |
| PresaleManager | `PRESALE_IMPL` | LaunchFactory | OZ `initializer` modifier, `_disableInitializers()` in constructor |
| LPStaking | `LP_STAKING_IMPL` | PresaleManager (during seedLiquidity) | `setInitializer(presale)` by factory, `initAuthorizer` state var |
| VestingStream | `VESTING_IMPL` | PresaleManager (during seedLiquidity) | `setInitializer(presale, issuer)` by factory, `initAuthorizer` + `issuer` state vars |

**Note**: All 5 clones use OpenZeppelin's `Initializable` base with `_disableInitializers()` in constructors and `initializer` modifier. Custom `AlreadyInitialized` errors replaced by OZ's `InvalidInitialization`. Events renamed to avoid conflict with OZ's `Initialized(uint64)`: `TokenInitialized`, `PresaleInitialized`, `VestingInitialized`. Express path launches don't deploy VestingStream (4 clones instead of 5).

---

### Singletons (deployed once, shared across all launches)

| Contract | Shared Across |
|----------|--------------|
| LaunchFactory | All launches (one per mode: boardwalk-only, integrator) |
| BoardwalkLPManager | All launches |
| BoardwalkFeeCollector | All launches |
| BoostBurn | All tokens (global ranking) |
| GovernanceVoter | Base governance (voting + execution + vault) |
| LPLocker | Base governance (permanent v4 LP positions) |
| ParticipationDistributor | Base governance (Option 4 BMX streaming) |
| UniswapV2Factory | All pairs |
| UniswapV2Router02 | All swaps |

---

## New Features

### Integrator Fee Structure (Feature 1)

Total tax changed from 80 to **115 BPS**. Two deployment modes via separate factory instances:

**Boardwalk-only factory:** `{issuer: 40, boardwalk: 45, incentive: 30, referrer: 5, integrator: 0, total: 115}`
- Referrer carved from boardwalk (existing pattern): if referrer exists, boardwalk effective = 40.

**Integrator factory:** `{issuer: 35, boardwalk: 30, incentive: 25, referrer: 0, integrator: 25, total: 115}`
- No referrer. Integrator address timelocked-changeable on factory (future launches only). Permanent per-launch on FeeDistributor.
- Integrator claims fees in native token (no rate limit, same pattern as referrer).

Key changes: `LaunchFactory` has `integrator` state + `isLaunchToken()` view + `signalAction(SET_INTEGRATOR, dataHash)` / `executeSetIntegrator`. `FeeDistributor.InitParams` has `integrator` + `integratorBps` fields. `FeeDistributor.onTaxReceived` splits integrator share.

---

### BoostBurn (Feature 2)

**Purpose:** Community-driven token discovery ranking. Any wallet burns BMX to boost or deboost any token's score.

**Inherits**: Ownable2Step, Timelocked, MembershipDiscount

**Key Properties:**
- `int256 scores[token]`: net score per token (can be negative)
- One interaction per `(wallet, token, epoch)` per 30-day epoch
- BMX burned to DEAD_ADDRESS (default 0.1 BMX; owner adjusts cost via `signalAction(SET_BMX_COST, dataHash)` / typed `executeSetBmxCost`, 0–1 BMX)
- `memberBoostDiscountBps`: BPS discount on BMX cost for NFT members (0-10000, default: 10000 = free)
- `nftCollection`: NFT collection address for membership check (inherited from MembershipDiscount; address(0) = disabled)
- Accepts any token address (no factory validation)
- Epoch calculation: `(block.timestamp - EPOCH_ZERO) / 30 days`
- NFT members pay discounted BMX cost (default 100% discount = free); owner adjusts via `executeSetMemberBoostDiscount` / `executeSetNftCollection`

---

### Governance Voting System (Feature 3, Base-only)

**Architecture:** `BoardwalkFeeCollector` splits post-swap raise token 30% treasury / 70% GovernanceVoter. GovernanceVoter is a merged voter + executor + vault. Peers (`lpLocker`, `participationDistributor`) are wired once via `initializePeers(address,address)` after deployment and validated bidirectionally (deploy order: GovernanceVoter → LPLocker(voter) → ParticipationDistributor(voter) → initializePeers).

**Weekly Vote Lifecycle:**
1. `vote(option)`: sbfBMX holders vote in epoch N to direct epoch N+1 fees. Weight = `sbfBMX.balanceOf(voter)` at vote time. Blocked during finalization.
2. `finalize(N, maxBatch)`: keeper-or-owner only. Validates epoch N-1 voters in batches, applies quorum/winner logic using epoch N-1 vote weights, and snapshots epoch N budget as `currentBalance - accountedBudget`. Epoch 0 defaults to treasury (no prior votes).
3. `execute(N, amountOutMin)`: keeper-or-owner only. Executes epoch N winner with caller-supplied slippage protection and decrements `accountedBudget`.
4. `forceMarkExecuted(epoch)`: permissionless deadlock resolver. Callable 14 days after epoch end, routes budget to `fallbackTreasury` and also decrements `accountedBudget`.

**Sequential finalization rule:** epoch `N-1` must be finalized **and executed** before epoch `N` can be finalized.

**Key State Variables (batching + budget accounting):**
- `epochVoters[epoch]`: array of voter addresses for re-validation during finalization
- `validationCursor[epoch]`: batch cursor tracking progress through voter array
- `finalizationInProgress`: flag checked by RewardRouterV5 to block staking during tally
- `finalizingEpoch`: tracks which epoch is mid-finalization (prevents cross-epoch continuation)
- `accountedBudget`: tracks finalized-but-not-executed budgets to prevent double-counting vault balance

**Quorum & Winner Selection:**
- Preferred: `finalize(N)` snapshots `sbfBMX.totalSupply()` for epoch N+1 before votes begin.
- Fallback: first `vote()` of an epoch snapshots if prior epoch wasn't finalized.
- At finalization: quorum denominator = `min(snapshotTotalWeight, live totalSupply())`.
- Zero supply or zero total vote weight => no quorum (safe handling; no division-by-zero path).
- Re-validated: `totalVoteWeight` is reduced for any voter whose sbfBMX balance decreased since voting.
- Quorum threshold: `totalVoteWeight >= quorumBase * 51%`.
- Winner selection skips currently ineligible options (consecutive-win cap) and falls back to treasury if none qualify.

**Consecutive Win Cap:** An option winning 3 consecutive epochs is ineligible in the next epoch, returns after 1 epoch.

**Vote Options:**
1. **Treasury:** Transfer raise token to treasury (100% total with the automatic 30%)
2. **Buy & Burn BMX:** Unwrap WETH to native ETH, swap ETH→BMX via Universal Router (v4 pools use native ETH), burn BMX to DEAD_ADDRESS
3. **Buy & Burn LP:** Split budget 50/50. Swap half to BMX (via ETH). Mint Uniswap v4 LP position (ETH/BMX) through Universal Router's `V4_POSITION_MANAGER_CALL`, with SWEEP to recover excess ETH. Send position NFT to LPLocker. Caller supplies `liquidity` parameter and `amountOutMin` for slippage protection.
4. **Participation Allocation:** Swap to BMX (via ETH), stream to eligible voters via ParticipationDistributor (7-day linear vesting, eligibility = voted in prior epoch)

**Participation Points Gate:** Voting requires `stakedMP >= stakedBMX * 1.5%` (read from external Morphex sbfBMX contracts). Participation points are non-transferable and have no monetary value.

**Governance Burn:** Configurable 0-1 BMX burn per vote, 21-day timelocked (`signalAction(SET_GOVERNANCE_BURN, dataHash)` / `executeSetGovernanceBurn`; starts at 0).

**Treasury:** Mutable `treasury` address, initialized in constructor, changeable via `signalAction(SET_TREASURY, dataHash)` / `executeSetTreasury` (7-day delay). Used by `execute()` for Option 1 (transfer to treasury), Option 3 (leftover ETH, re-wrapped to WETH), and Option 4 (epoch 0 fallback). Non-zero address enforced in constructor and setter.

**Fallback Treasury:** Mutable `fallbackTreasury` address, initialized in constructor, changeable via `signalAction(SET_FALLBACK_TREASURY, dataHash)` / `executeSetFallbackTreasury` (21-day delay). Used only by `forceMarkExecuted`. The setter is itself burnable via per-action burn. Non-zero address enforced in constructor and setter.

**Events:** `EpochExecuted(uint256 indexed epoch, uint8 option, uint256 raiseTokenAmount, bool forced, address destination)` -- `forced=true` for `forceMarkExecuted`, `destination` records the actual transfer recipient. `TreasuryChanged(address oldAddress, address newAddress)` and `FallbackTreasuryChanged(address oldAddress, address newAddress)` for setters.

**Keeper:** Owner-configurable address that can call both `finalize()` and `execute()` (`signalAction(SET_KEEPER, dataHash)` / `executeSetKeeper`). Owner is also authorized for both functions. Keeper provides slippage protection for governance swaps.

**Batch Finalization Flow (Deli Voter pattern):**
1. Keeper or owner calls `finalize(epoch, maxBatch)` -- sets `finalizationInProgress = true`
2. For each voter in batch: re-read `sbfBMX.balanceOf(voter)`, if less than recorded weight reduce `optionWeights` and `totalVoteWeight`
3. If all voters validated: close finalization window (`finalizationInProgress = false`), compute quorum with `min(snapshot, liveSupply)`, skip ineligible options, determine winner, set finalized budget
4. During `finalizationInProgress`: `RewardRouterV5._stakeBmx()` reverts (prevents balance inflation mid-tally), `vote()` reverts

**LPLocker:** Holds Uniswap v4 LP position NFTs permanently. Tracks all locked tokenIds internally. Treasury is read dynamically from `GovernanceVoter.treasury()`. Currencies are `address(0)` (native ETH) and BMX. `claimFees(tokenId)` harvests trading fees by calling v4 `PositionManager.modifyLiquidities()` directly with `DECREASE_LIQUIDITY(liquidity=0)` + `TAKE_PAIR` (no Universal Router path) — the ETH portion of fees is sent as native ETH to treasury. `claimAllFees()` batch-harvests from all locked positions. `getLockedPositions()` returns all stored tokenIds. Has an open `receive()` to accept native ETH from PositionManager during fee claims.

**ParticipationDistributor:** Creates 7-day linear BMX streams for Option 4. Eligible voters (those who voted in the prior epoch) claim proportional share pull-based (no loops). `claimable(epoch, user)` returns both `totalAllocation` (full BMX share for the epoch) and `claimableAmount` (currently vested minus already claimed). `claimAll(uint256[] epochs)` batch-claims across multiple epochs in a single transaction (skips epochs with zero claimable, reverts if nothing claimable across all supplied epochs).

**Timelocked.sol:** Per-action delays are stored in `PendingChange.delay` (default via `_actionDelay` / `_burnDelay`). Owner flows use the public `signalAction` / `cancelAction` / burn helpers; typed `execute*` functions call `_execute`. Governance-sensitive actions use 21-day delay via overridden `_actionDelay` on GovernanceVoter. `_burnDelay` is intentionally NOT overridden in GovernanceVoter; it delegates to `_actionDelay()`, giving governance actions a 21-day burn delay and standard actions a 7-day burn delay.

**Native ETH (v4):** Uniswap v4 pools on Base use native ETH (`address(0)`), not WETH. GovernanceVoter unwraps WETH→ETH via `IWETH(WETH).withdraw()` before swaps and mints, sends ETH via `msg.value` to Universal Router, and uses `address(0)` as currency0 in pool keys (ETH always sorts below any contract address). A `receive()` function accepts ETH from WETH and PositionManager only. Leftover ETH after mints is recovered via SWEEP, re-wrapped to WETH, and sent to treasury.

**Action IDs (v4):** GovernanceVoter and LPLocker import action IDs from `@uniswap/v4-periphery/src/libraries/Actions.sol` (`SWAP_EXACT_IN_SINGLE`, `SETTLE`, `TAKE_ALL`, `TAKE_PAIR`, `SETTLE_PAIR`, `SWEEP`) instead of hardcoded values.

---

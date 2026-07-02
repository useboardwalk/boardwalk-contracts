# BWS CCA launch runbook (Arbitrum)

Launch BWS through Uniswap's **LiquidityLauncher + LBPStrategy** so unsold BWS burns, the LP lands in `LPLocker`, and the raise seeds the v4 pool. It's driven by direct contract calls; the only contract we deploy for it is `UnsoldBurner`.

## Steps

1. **Deploy** BWS + governance (`GovernanceVoter`, `LPLocker`) — scripts `01`–`02`. (BWS trackers/bnBWS come from the staking tooling; they're env inputs here.)
2. **Deploy `UnsoldBurner`** (record the address):
   ```
   BWS_TOKEN=<bws> CCA_REQUIRED_CURRENCY_RAISED=<threshold_wei> \
     forge script script/bws/05_DeployUnsoldBurner.s.sol --rpc-url $ARB_RPC --broadcast
   ```
3. **Launch** via script `06`, from the wallet holding 438,932 BWS:
   ```
   DEPLOYER_PRIVATE_KEY=<bucket wallet> BWS_TOKEN=<bws> GOVERNANCE_VOTER=<voter> LP_LOCKER=<locker> \
     UNSOLD_BURNER=<burner> LAUNCH_RECIPIENT=<treasury> \
     CCA_START_BLOCK=<L2 block> CCA_END_BLOCK=<L2 block> CCA_CLAIM_BLOCK=<L2 block> CCA_MIGRATION_BLOCK=<L2 block> \
     CCA_TICK_SPACING_Q96=<q96> CCA_FLOOR_PRICE_Q96=<q96> CCA_REQUIRED_CURRENCY_RAISED=<threshold_wei> \
     CCA_AUCTION_STEPS=<0x-packed steps> \
     forge script script/bws/06_LaunchBwsCca.s.sol --rpc-url $ARB_RPC --broadcast
   ```
   The script sanity-checks the whole wiring (bucket balance, burner/locker/voter, block ordering, step schedule, Q96 price bounds), funds the launcher via Permit2 and batches `depositToken` + `distributeToken` in ONE `multicall` (the launcher has no per-depositor accounting — tokens parked between separate txs are distributable by anyone). The strategy creates + registers the CCA (auction bucket 219,466, LP reserve 219,466); the script prints the CREATE2-predicted auction (initializer) address and verifies the simulated post-state against it — **record it**. Block fields are ArbSys L2 block numbers; prices are Q96 (`wei-per-wei ratio << 96`); steps pack `uint24 mps + uint40 blockDelta` per 8 bytes, with `mps*delta` summing to 1e7 and the deltas spanning exactly `start..end`.
4. **Migrate** — after `endBlock`/`migrationBlock`, someone must call `LBPStrategy.migrate(initializer)`. It's permissionless but nothing automates it; it sweeps the raise, initializes the pool, mints the LP to `LPLocker`, and emits `Migrated`. Nothing exists (pool, LP, event) before this call.
5. **Wire governance** from the migrate tx:
   - **Hook** — `Migrated.key` is indexed, so read the hook from the same tx's PoolManager `Initialize` event (or `getPoolAndPositionInfo(tokenId)`), verify `keccak256(abi.encode(key))` matches the `Migrated` topic, then call the one-shot `GovernanceVoter.setPoolHooks(hook)`. Expect `address(0)` — or the LBPStrategy address, if the hookless pool was front-run and the strategy fell back to itself.
   - **Positions** — the planner can mint several positions. Register EVERY `Transfer(0x0 → LPLocker)` id via `LPLocker.registerPosition`, confirm `getLockedPositions().length`, then `renounceRegistrar()`. Any position left unregistered has its fees stranded once the registrar is gone.
6. **Migrator** — deploy/root/fund via script `03` (**root before funding**), have morphex gov run the printed grants, then run the go-live gate `04` with the full env (`STAKING_GOV`, `CCA_AUCTION`, `UNSOLD_BURNER`, `LP_LOCKER`) so the launch-wiring checks run.
7. **Burn unsold** — after the auction ends, anyone calls `UnsoldBurner.sweep(auction)` (pulls the auction's unsold BWS — all of it if it didn't graduate — to `0x…dEaD`). `UnsoldBurner.burn()` clears any BWS already sitting on the burner.

## Key parameters

`configData = abi.encode(MigratorParameters, abi.encode(AuctionParameters))` — script `06` builds and encodes all of this; the tables below are what it commits to.

**AuctionParameters:**
- `currency` = `address(0)` (native ETH raise)
- `tokensRecipient` = `UnsoldBurner` (non-zero, not `address(1)`)
- `requiredCurrencyRaised` = graduation threshold (raise-token wei); graduates iff `currencyRaised >= requiredCurrencyRaised`
- `fundsRecipient` = `LBPStrategy` (required — the strategy validates this and sweeps the raise on migrate)
- offered `amount` = 219,466 BWS (the 438,932 distributed minus the LP reserve)

**MigratorParameters:**
- `token` / `currency` = BWS / `address(0)` (must match the auction)
- `migrationBlock` > auction `endBlock`
- `reservedTokenAmountForLP` = `219_466e18`
- `recipient` = controlled treasury/launch wallet — receives leftover currency + LP-reserve BWS, and the **entire** 219,466 back (not burned) on non-graduation or a failed migration
- `positionRecipient` = `LPLocker`
- `poolParameters.fee` / `tickSpacing` — the script reads them live from `GovernanceVoter.POOL_FEE`/`POOL_TICK_SPACING` (both immutable, canonically `10_000`/`200`) or vote options 2/3/4 would target a nonexistent pool
- `poolParameters.hook` = `address(0)` — read the real hook post-migrate (step 5)
- `positionDefinitions` = one full-range sentinel definition at 100% weight with no `overridePositionRecipient` (everything lands in the locker); `lpAllocationSchedule` = a single `{0, 1e7}` bracket (100% of the raise to LP, excess on either side swept to `recipient`)

## Sweep semantics

`sweepUnsoldTokens()` is recipient-gated, one-shot, and only callable after the auction ends; `UnsoldBurner` calls it from `sweep(auction)`. Non-graduation returns the full offered supply to `tokensRecipient` (→ DEAD), bidders are refunded their ETH, and the LP seed returns to `recipient` (not burned).

## Arbitrum addresses (byte-verify before launch)

- CCA factory — `0x00cCa200BF124dBfA848937c553864f4B4CE0632`
- LiquidityLauncher — `0x00004c4ccc709Ef590F7C81102C0689F0263D4e9`
- LBPStrategy — `0x18608AD558dcD233F7854242bbAef73988Bee000`
- CCALens — `0xc3C65F5453A3674aDb693cbdA3C842545cD30f53`

All four have code on Arbitrum One (`test/fork/UnsoldBurnerFork.t.sol` gates on it).

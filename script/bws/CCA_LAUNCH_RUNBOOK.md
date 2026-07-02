# BWS CCA launch runbook (Arbitrum)

Launch BWS through Uniswap's **LiquidityLauncher + LBPStrategy** so unsold BWS burns, the LP lands in `LPLocker`, and the raise seeds the v4 pool. It's driven by direct contract calls; the only contract we deploy for it is `UnsoldBurner`.

## Steps

1. **Deploy** BWS + governance (`GovernanceVoter`, `LPLocker`) — scripts `01`–`02`. (BWS trackers/bnBWS come from the staking tooling; they're env inputs here.)
2. **Deploy `UnsoldBurner`** (record the address):
   ```
   BWS_TOKEN=<bws> CCA_REQUIRED_CURRENCY_RAISED=<threshold_wei> \
     forge script script/bws/05_DeployUnsoldBurner.s.sol --rpc-url $ARB_RPC --broadcast
   ```
3. **Launch** from the wallet holding 438,932 BWS:
   ```
   BWS.approve(LiquidityLauncher, 438_932e18)
   LiquidityLauncher.depositToken(BWS, 438_932e18)
   LiquidityLauncher.distributeToken(BWS, Distribution({ strategy: LBPStrategy, amount: 438_932e18,
     configData: abi.encode(MigratorParameters, abi.encode(AuctionParameters)) }), salt)
   ```
   The strategy creates + registers the CCA (auction bucket 219,466, LP reserve 219,466) and emits the auction (initializer) address — record it.
4. **Migrate** — after `endBlock`/`migrationBlock`, someone must call `LBPStrategy.migrate(initializer)`. It's permissionless but nothing automates it; it sweeps the raise, initializes the pool, mints the LP to `LPLocker`, and emits `Migrated`. Nothing exists (pool, LP, event) before this call.
5. **Wire governance** from the migrate tx:
   - **Hook** — `Migrated.key` is indexed, so read the hook from the same tx's PoolManager `Initialize` event (or `getPoolAndPositionInfo(tokenId)`), verify `keccak256(abi.encode(key))` matches the `Migrated` topic, then call the one-shot `GovernanceVoter.setPoolHooks(hook)`. Expect `address(0)` — or the LBPStrategy address, if the hookless pool was front-run and the strategy fell back to itself.
   - **Positions** — the planner can mint several positions. Register EVERY `Transfer(0x0 → LPLocker)` id via `LPLocker.registerPosition`, confirm `getLockedPositions().length`, then `renounceRegistrar()`. Any position left unregistered has its fees stranded once the registrar is gone.
6. **Migrator** — deploy/root/fund via script `03` (**root before funding**), have morphex gov run the printed grants, then run the go-live gate `04` with the full env (`STAKING_GOV`, `CCA_AUCTION`, `UNSOLD_BURNER`, `LP_LOCKER`) so the launch-wiring checks run.
7. **Burn unsold** — after the auction ends, anyone calls `UnsoldBurner.sweep(auction)` (pulls the auction's unsold BWS — all of it if it didn't graduate — to `0x…dEaD`). `UnsoldBurner.burn()` clears any BWS already sitting on the burner.

## Key parameters

`configData = abi.encode(MigratorParameters, abi.encode(AuctionParameters))`.

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
- `poolParameters.fee` = `10_000`, `tickSpacing` = `200` — **must** equal `GovernanceVoter.POOL_FEE`/`POOL_TICK_SPACING` (both immutable) or vote options 2/3 target a nonexistent pool
- `poolParameters.hook` = `address(0)` — read the real hook post-migrate (step 5)
- keep `positionDefinitions` without `overridePositionRecipient` so everything lands in the locker

## Sweep semantics

`sweepUnsoldTokens()` is recipient-gated, one-shot, and only callable after the auction ends; `UnsoldBurner` calls it from `sweep(auction)`. Non-graduation returns the full offered supply to `tokensRecipient` (→ DEAD), bidders are refunded their ETH, and the LP seed returns to `recipient` (not burned).

## Arbitrum addresses (byte-verify before launch)

- CCA factory — `0x00cCa200BF124dBfA848937c553864f4B4CE0632`
- LiquidityLauncher — `0x00004c4ccc709Ef590F7C81102C0689F0263D4e9`
- LBPStrategy — `0x18608AD558dcD233F7854242bbAef73988Bee000`
- CCALens — `0xc3C65F5453A3674aDb693cbdA3C842545cD30f53`

All four have code on Arbitrum One (`test/fork/UnsoldBurnerFork.t.sol` gates on it).

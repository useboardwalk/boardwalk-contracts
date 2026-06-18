# Boardwalk Launchpad

Permissionless token launch protocol with embedded transfer tax, time-weighted presale, permanently burned liquidity, LP staking, community ranking, and (on Base) onchain governance over protocol revenue.

Deployed across Ethereum, Base, Arbitrum, Ink, Katana, and Fraxtal. Membership NFTs bridge between chains via Chainlink CCIP, and non-Base protocol revenue is consolidated to Base.

See [SPEC.md](SPEC.md) for the full spec.

## Architecture

Each launch deploys 4–5 [EIP-1167](https://eips.ethereum.org/EIPS/eip-1167) clones from shared implementation templates. Singletons are deployed once per chain.

```mermaid
graph LR
    subgraph SINGLETONS [Singletons]
        direction TB
        LF[LaunchFactory]
        LPM[BoardwalkLPManager]
        FC[BoardwalkFeeCollector]
        BB[BoostBurn]
        DEX[DEX Factory + Router]
    end

    subgraph GOVERNANCE [Base-only]
        direction TB
        GV[GovernanceVoter]
        LPL[LPLocker]
        PD[ParticipationDistributor]
    end

    subgraph CLONES [Per-launch clones]
        direction TB
        TK[BoardwalkToken]
        FD[FeeDistributor]
        PM[PresaleManager]
        LS[LPStaking]
        VS[VestingStream]
    end

    LF -- deploys --> TK
    LF -- deploys --> FD
    LF -- deploys --> PM
    LF -- deploys --> LS
    LF -- deploys --> VS

    TK -. tax callback .-> FD
    FD -. LP fees .-> LS
    FD -. protocol fees .-> FC
    FC -. 30% treasury .-> TR[Treasury]
    FC -. 70% governance .-> GV
    PM -. seeds liquidity .-> DEX
    LPM -. tax-free LP ops .-> DEX
```

## Repository layout

```
src/
  base/
    Timelocked.sol          signal/execute/burn + auth hooks (7d default, 21d for governance)
    AllocationLib.sol       shared token allocation math
    MembershipDiscount.sol  NFT membership check + BPS discount helpers
  core/
    LaunchFactory.sol       clone deployment and admin config
    BoardwalkToken.sol      ERC20 with embedded tax
    FeeDistributor.sol      tax routing to 5 destinations
    PresaleManager.sol      contributions, seeding, claims, refunds
    LPStaking.sol           staking with vesting + fee epochs + MP
    VestingStream.sol       linear vesting with 7-day cliff
    BoardwalkLPManager.sol  tax-exempt LP wrapper (RAISE_TOKEN pairs only)
    BoardwalkFeeCollector.sol protocol fee aggregation + 30/70 governance split
    IntegratorFeeCollector.sol per-chain protocol singleton with frozen integrator slots, 25%/24h rate-limited claims
    BoostBurn.sol           community token ranking via BMX burn
  governance/                Base only
    GovernanceVoter.sol     weekly voting + execution + vault
    LPLocker.sol            permanent Uniswap v4 LP lock with fee harvest
    ParticipationDistributor.sol 7-day BMX streaming for Option 4
  nft/                       cross-chain membership NFT (Chainlink CCIP bridge)
    BoardwalkClub.sol       (deprecated) soulbound membership NFT; superseded by BoardwalkClubMirror
    BoardwalkClubBridgeBase.sol shared CCIP send/receive plumbing
    BoardwalkClubLockbox.sol Base side: lock/release of the original collection
    BoardwalkClubMirror.sol  spoke side: burn/mint transferable mirror
  crosschain/                weekly consolidation of non-Base revenue to Base
    RevenueBridger.sol      non-Base lanes: forward revenue to Base via LiFi (Across/Symbiosis/Glacis)
    BaseRevenueSwapper.sol  Base: swap delivered tokens to WETH, forward to the FeeCollector
  interfaces/                cross-contract interfaces
  dex/                       forked Uniswap V2 (0.1% pair fee)
test/                        unit, fuzz, invariant, fork
script/                      deployment scripts
```

## Build and test

```bash
forge build
forge test
forge coverage --ir-minimum --skip "*/dex/*" --skip "script/*" --report summary
forge fmt src/base/ src/core/ src/interfaces/ src/governance/ src/nft/ src/crosschain/
forge lint src/base/ src/core/ src/interfaces/ src/governance/ src/nft/ src/crosschain/
```

## Deployment

```bash
forge script script/01_DeployDEX.s.sol --rpc-url $RPC_URL --broadcast
forge script script/02_DeployFactory.s.sol --rpc-url $RPC_URL --broadcast
forge script script/03_DeployGovernance.s.sol --rpc-url $RPC_URL --broadcast       # Base only
forge script script/04_DeployNFTBridge.s.sol --rpc-url $RPC_URL --broadcast        # Base lockbox + spoke mirrors
forge script script/05_WireLockboxPeers.s.sol --rpc-url $RPC_URL --broadcast       # one-shot CCIP peer wiring
forge script script/06_DeployRevenueBridging.s.sol --rpc-url $RPC_URL --broadcast  # Base swapper first, then each lane
```

## Audits

Reports land in `./audits/` once available.

## License

[BUSL-1.1](LICENSE), converts to MIT on 2030-02-13. The `src/dex/` fork retains its upstream license.

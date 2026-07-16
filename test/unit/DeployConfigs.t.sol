// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {LaunchFactory} from "src/core/LaunchFactory.sol";
import {FeeSchedules} from "script/FeeSchedules.sol";
import {DexConfig} from "script/DexConfig.sol";
import {CCIPConfig} from "script/CCIPConfig.sol";
import {CrossChainConfig} from "script/CrossChainConfig.sol";

/// @title DeployConfigsTest
/// @notice Pins the production deploy-config literals: the unified fee schedule, the integrator
///         slot table, and the per-chain Uniswap V2 / CCIP resolution. A drift here is a deploy
///         defect, not a code defect.
contract DeployConfigsTest is Test {
    uint256[4] internal supportedChains = [
        FeeSchedules.CHAIN_ETHEREUM, FeeSchedules.CHAIN_BASE, FeeSchedules.CHAIN_ARBITRUM, FeeSchedules.CHAIN_ROBINHOOD
    ];

    // Removed chains must not resolve anywhere.
    uint256[3] internal removedChains = [uint256(252), 747474, 57073]; // Fraxtal, Katana, Ink

    /* ------------------------------- fee schedule ------------------------------- */

    function test_FeeSchedule_UnifiedAcrossAllChains() public pure {
        uint256[4] memory chains = [
            FeeSchedules.CHAIN_ETHEREUM,
            FeeSchedules.CHAIN_BASE,
            FeeSchedules.CHAIN_ARBITRUM,
            FeeSchedules.CHAIN_ROBINHOOD
        ];
        for (uint256 i = 0; i < chains.length; i++) {
            (LaunchFactory.FeeBpsDefaults memory feeBps, uint256 integratorBps) = FeeSchedules.resolve(chains[i]);
            assertEq(feeBps.issuer, 35, "issuer 0.35%");
            assertEq(feeBps.boardwalk, 35, "boardwalk 0.35% (Express; Advanced-with-referrer 30+5)");
            assertEq(feeBps.incentive, 15, "LP incentive 0.15%");
            assertEq(feeBps.referrer, 5, "referrer carve-out 0.05%");
            assertEq(feeBps.total, 95, "token tax 0.95% (+ Uniswap V2 0.30% = 1.25%)");
            assertEq(feeBps.total, feeBps.issuer + feeBps.boardwalk + feeBps.incentive + integratorBps, "total = sum");
            assertEq(integratorBps, 10, "integrator bucket 0.10%");
        }
    }

    function test_FeeSchedule_IntegratorSlots() public {
        for (uint256 i = 0; i < supportedChains.length; i++) {
            (address[] memory addrs, uint256[] memory splits, uint256 totalBps) =
                FeeSchedules.integratorConfig(supportedChains[i]);

            assertEq(addrs.length, 5, "five integrator slots");
            assertEq(totalBps, 10, "integrator bucket 0.10%");

            uint256 splitSum;
            for (uint256 j = 0; j < splits.length; j++) {
                assertEq(splits[j], 2000, "equal 2 bps slots -> 2000 split each");
                splitSum += splits[j];
            }
            assertEq(splitSum, 10_000, "splits sum to denominator");

            assertEq(addrs[0], 0xd35F65B1f0912bD13a07A21374615cfeC073Dc67, "Sherlock");
            assertEq(addrs[1], FeeSchedules.PENDING_INTEGRATOR, "DefiLlama Research pending (env-filled at deploy)");
            assertEq(addrs[2], 0x3C241dAF101F697044ee076B51baEe5B0d72c0dc, "0x");
            assertEq(addrs[3], 0x5EA1d9A6dDC3A0329378a327746D71A2019eC332, "SEAL");
            assertEq(addrs[4], 0x08a3c2A819E3de7ACa384c798269B3Ce1CD0e437, "DeFi Llama");
        }
    }

    function test_FeeSchedule_SatisfiesFactoryBounds() public {
        // The schedule must construct: bounds are enforced in the LaunchFactory constructor via
        // _validateFeeDefaults. Deploy a factory with the production schedule to prove it.
        (LaunchFactory.FeeBpsDefaults memory feeBps, uint256 integratorBps) =
            FeeSchedules.resolve(FeeSchedules.CHAIN_ETHEREUM);

        LaunchFactory factory = new LaunchFactory(
            address(this),
            LaunchFactory.DeployParams({
                tokenImpl: makeAddr("tokenImpl"),
                feeDistributorImpl: makeAddr("fdImpl"),
                presaleImpl: makeAddr("presaleImpl"),
                vestingImpl: makeAddr("vestingImpl"),
                lpStakingImpl: makeAddr("lpImpl"),
                bwlk: makeAddr("bwlk"),
                raiseToken: makeAddr("weth"),
                boardwalkRouter: makeAddr("router"),
                boardwalkDexFactory: makeAddr("factory"),
                boardwalkLpManager: makeAddr("lpManager"),
                boardwalkFeeCollector: makeAddr("collector"),
                integratorCollector: makeAddr("integratorCollector"),
                integratorBps: integratorBps,
                bwlkBurnAmount: 100e18,
                graduationExpress: 5 ether,
                graduationAdvanced: 5 ether,
                expressDuration: 24 hours,
                advancedDuration: 7 days,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: feeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );

        (uint256 issuer, uint256 boardwalk, uint256 incentive, uint256 referrer, uint256 integrator, uint256 total) =
            factory.currentFeeBps();
        assertEq(issuer, 35, "issuer");
        assertEq(boardwalk, 35, "boardwalk");
        assertEq(incentive, 15, "incentive");
        assertEq(referrer, 5, "referrer");
        assertEq(integrator, 10, "integrator");
        assertEq(total, 95, "total");
    }

    function test_RevertWhen_FeeSchedule_RemovedChain() public {
        for (uint256 i = 0; i < removedChains.length; i++) {
            uint256 chainId = removedChains[i];
            vm.expectRevert(abi.encodeWithSelector(FeeSchedules.UnsupportedChainId.selector, chainId));
            this.resolveFees(chainId);
        }
    }

    /* --------------------------------- dex config -------------------------------- */

    function test_DexConfig_ResolvesCanonicalUniswapV2() public pure {
        (address f1, address r1, address w1) = DexConfig.resolve(DexConfig.CHAIN_ETHEREUM);
        assertEq(f1, 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f, "eth factory");
        assertEq(r1, 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D, "eth router");
        assertEq(w1, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, "eth weth");

        (address f2, address r2, address w2) = DexConfig.resolve(DexConfig.CHAIN_BASE);
        assertEq(f2, 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6, "base factory");
        assertEq(r2, 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24, "base router");
        assertEq(w2, 0x4200000000000000000000000000000000000006, "base weth");

        (address f3, address r3, address w3) = DexConfig.resolve(DexConfig.CHAIN_ARBITRUM);
        assertEq(f3, 0xf1D7CC64Fb4452F05c498126312eBE29f30Fbcf9, "arb factory");
        assertEq(r3, 0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24, "arb router");
        assertEq(w3, 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, "arb weth");

        (address f4, address r4, address w4) = DexConfig.resolve(DexConfig.CHAIN_ROBINHOOD);
        assertEq(f4, 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f, "robinhood factory");
        assertEq(r4, 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba, "robinhood router");
        assertEq(w4, 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, "robinhood weth");
    }

    function test_RevertWhen_DexConfig_RemovedChain() public {
        for (uint256 i = 0; i < removedChains.length; i++) {
            uint256 chainId = removedChains[i];
            vm.expectRevert(abi.encodeWithSelector(DexConfig.UnsupportedChainId.selector, chainId));
            this.resolveDex(chainId);
        }
    }

    /* ----------------------------- crosschain config ----------------------------- */

    function test_CrossChainConfig_PinsLaneLiterals() public pure {
        assertEq(CrossChainConfig.ETHEREUM_CHAIN_ID, 1, "hub chain id");
        assertEq(CrossChainConfig.ETHEREUM_WETH, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, "hub weth");
        assertEq(
            CrossChainConfig.ZEROX_ALLOWANCE_HOLDER, 0x0000000000001fF3684f28c67538d4D072C22734, "allowance holder"
        );
        assertEq(CrossChainConfig.ACROSS_V4_SELECTOR, bytes4(0xa1f1ce43), "across v4 selector");

        assertEq(
            CrossChainConfig.lifiDiamond(CrossChainConfig.CHAIN_BASE),
            0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE,
            "base diamond"
        );
        assertEq(
            CrossChainConfig.lifiDiamond(CrossChainConfig.CHAIN_ARBITRUM),
            0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE,
            "arb diamond"
        );
        assertEq(
            CrossChainConfig.lifiDiamond(CrossChainConfig.CHAIN_ROBINHOOD),
            0xB477751B76CF82d00a686A1232f5fCD772414Af3,
            "robinhood diamond"
        );

        assertEq(
            CrossChainConfig.laneRaiseToken(CrossChainConfig.CHAIN_BASE),
            0x4200000000000000000000000000000000000006,
            "base lane weth"
        );
        assertEq(
            CrossChainConfig.laneRaiseToken(CrossChainConfig.CHAIN_ARBITRUM),
            0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,
            "arb lane weth"
        );
        assertEq(
            CrossChainConfig.laneRaiseToken(CrossChainConfig.CHAIN_ROBINHOOD),
            0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73,
            "robinhood lane weth"
        );
    }

    /* -------------------------------- ccip config -------------------------------- */

    function test_CCIPConfig_ResolvesAllSupportedChains() public pure {
        (address rEth, uint64 sEth) = CCIPConfig.resolve(CCIPConfig.CHAIN_ETHEREUM);
        assertEq(rEth, 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D, "eth router");
        assertEq(sEth, 5009297550715157269, "eth selector");

        (address rBase, uint64 sBase) = CCIPConfig.resolve(CCIPConfig.CHAIN_BASE);
        assertEq(rBase, 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD, "base router");
        assertEq(sBase, 15971525489660198786, "base selector");

        (address rArb, uint64 sArb) = CCIPConfig.resolve(CCIPConfig.CHAIN_ARBITRUM);
        assertEq(rArb, 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8, "arb router");
        assertEq(sArb, 4949039107694359620, "arb selector");

        (address rRh, uint64 sRh) = CCIPConfig.resolve(CCIPConfig.CHAIN_ROBINHOOD);
        assertEq(rRh, 0x06fC836cf9839B1cd891C440A0a45242DA6Ae1c9, "robinhood router");
        assertEq(sRh, 6180753054346818345, "robinhood selector");
    }

    function test_RevertWhen_CCIPConfig_RemovedChain() public {
        for (uint256 i = 0; i < removedChains.length; i++) {
            uint256 chainId = removedChains[i];
            vm.expectRevert(abi.encodeWithSelector(CCIPConfig.UnsupportedChainId.selector, chainId));
            this.resolveCcip(chainId);
        }
    }

    /* ---------------- external wrappers so expectRevert catches library reverts ---------------- */

    function resolveFees(
        uint256 chainId
    ) external pure returns (LaunchFactory.FeeBpsDefaults memory feeBps, uint256 integratorBps) {
        return FeeSchedules.resolve(chainId);
    }

    function resolveDex(
        uint256 chainId
    ) external pure returns (address, address, address) {
        return DexConfig.resolve(chainId);
    }

    function resolveCcip(
        uint256 chainId
    ) external pure returns (address, uint64) {
        return CCIPConfig.resolve(chainId);
    }
}

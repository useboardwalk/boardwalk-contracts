// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {BoardwalkToken} from "src/core/BoardwalkToken.sol";
import {FeeDistributor} from "src/core/FeeDistributor.sol";
import {PresaleManager} from "src/core/PresaleManager.sol";
import {VestingStream} from "src/core/VestingStream.sol";
import {LPStaking} from "src/core/LPStaking.sol";
import {LaunchFactory} from "src/core/LaunchFactory.sol";
import {BoardwalkLPManager} from "src/core/BoardwalkLPManager.sol";
import {BoardwalkFeeCollector} from "src/core/BoardwalkFeeCollector.sol";
import {IntegratorFeeCollector} from "src/core/IntegratorFeeCollector.sol";
import {BoostBurn} from "src/core/BoostBurn.sol";
import {IDEXRouter} from "src/interfaces/IDEXRouter.sol";
import {FeeSchedules} from "script/FeeSchedules.sol";
import {DexConfig} from "script/DexConfig.sol";

/// @title DeployFactory
/// @notice Deploys the full Boardwalk per-chain stack: membership NFT, implementation templates,
///         singletons, the per-chain integrator collector, the LaunchFactory, and BoostBurn.
/// @dev NFT_COLLECTION is REQUIRED: the SeaDrop collection on Base, the chain's deployed
///      `BoardwalkClubMirror` on spokes (run 04_DeployNFTBridge first on a new spoke). An explicit
///      zero address disables membership discounts. There is no fallback deploy — wiring the
///      deprecated soulbound gate by omission would cost a 7-day SET_NFT_COLLECTION timelock on
///      both LaunchFactory and BoostBurn to fix.
///      Deployment order:
///      1. Implementation templates (5 contracts)
///      2. BoardwalkLPManager (singleton)
///      3. BoardwalkFeeCollector (singleton)
///      4. IntegratorFeeCollector (per-chain singleton; frozen integrators[]/splits[] from FeeSchedules)
///      5. LaunchFactory (singleton — wires everything, including the membership NFT)
///      6. integratorCollector.setFactory(factory) — one-shot to break the chicken-and-egg
///      7. BoostBurn (community ranking; wired to the same membership NFT)
contract DeployFactory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        // Canonical Uniswap V2 + WETH for this chain. Env overrides exist for fork rehearsals with a
        // nonstandard v2 deployment; FeeSchedules.resolve below pins the supported chain set regardless.
        (address canonicalFactory, address canonicalRouter, address canonicalWeth) = DexConfig.resolve(block.chainid);
        address dexFactory = vm.envOr("DEX_FACTORY", canonicalFactory);
        address dexRouter = vm.envOr("DEX_ROUTER", canonicalRouter);
        address owner = vm.envOr("OWNER", deployer);
        address bwlk = vm.envAddress("BWLK_ADDRESS");
        address raiseToken = vm.envOr("RAISE_TOKEN_ADDRESS", canonicalWeth);
        address treasury = vm.envOr("TREASURY", owner);
        address keeper = vm.envAddress("KEEPER");
        uint256 bwlkBurnAmount = vm.envOr("BWLK_BURN_AMOUNT", uint256(100e18));
        uint256 graduationExpress = vm.envOr("GRADUATION_EXPRESS", uint256(2.5 ether));
        uint256 graduationAdvanced = vm.envOr("GRADUATION_ADVANCED", uint256(2.5 ether));
        uint256 expressDuration = vm.envOr("EXPRESS_DURATION", uint256(24 hours));
        uint256 advancedDuration = vm.envOr("ADVANCED_DURATION", uint256(7 days));
        // Required (fail-loud): SeaDrop collection on Base, the chain's mirror on spokes; an
        // explicit zero disables discounts.
        address nftCollection = vm.envAddress("NFT_COLLECTION");
        uint256 memberLaunchDiscountBps = vm.envOr("MEMBER_LAUNCH_DISCOUNT_BPS", uint256(5000));

        // Anti-whale defaults — preserve previous hardcoded values unless env overrides.
        uint256 antiWhaleTaxBps = vm.envOr("ANTI_WHALE_TAX_BPS", uint256(4000));
        uint256 antiWhaleDuration = vm.envOr("ANTI_WHALE_DURATION", uint256(90 minutes));

        // BoostBurn (community ranking) config.
        uint256 epochZero = vm.envOr("EPOCH_ZERO", block.timestamp);
        uint256 epochDuration = vm.envOr("EPOCH_DURATION", uint256(30 days));
        uint256 memberBoostDiscountBps = vm.envOr("MEMBER_BOOST_DISCOUNT_BPS", uint256(5000));

        require(owner != address(0), "OWNER required");
        require(bwlk != address(0), "BWLK_ADDRESS required");
        require(raiseToken != address(0), "RAISE_TOKEN_ADDRESS required");
        require(dexFactory != address(0), "DEX_FACTORY required");
        require(dexRouter != address(0), "DEX_ROUTER required");
        require(treasury != address(0), "TREASURY required");
        require(keeper != address(0), "KEEPER required");
        require(dexFactory.code.length > 0, "DEX factory: no code");
        require(dexRouter.code.length > 0, "DEX router: no code");
        require(IDEXRouter(dexRouter).factory() == dexFactory, "router/factory mismatch");

        // Frozen per-chain integrator recipients + splits, derived from each integrator's absolute
        // fee. The IntegratorFeeCollector constructor re-validates distinctness/non-zero/sum==10000.
        (address[] memory integratorAddresses, uint256[] memory integratorSplits, uint256 totalIntegratorBps) =
            FeeSchedules.integratorConfig(block.chainid);

        // Per-chain fee defaults + integrator bucket size. Integrator BPS is immutable on the factory
        // (not in `feeBps`) and cannot be adjusted post-deployment.
        (LaunchFactory.FeeBpsDefaults memory feeBps, uint256 integratorBps) = FeeSchedules.resolve(block.chainid);
        require(totalIntegratorBps == integratorBps, "integrator bps mismatch");

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Boardwalk Factory Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Owner:", owner);
        console.log("Chain id:", block.chainid);
        console.log("NFT collection (membership gate):", nftCollection);

        // 1. Deploy implementation templates
        BoardwalkToken tokenImpl = new BoardwalkToken();
        console.log("BoardwalkToken template:", address(tokenImpl));

        FeeDistributor feeDistributorImpl = new FeeDistributor();
        console.log("FeeDistributor template:", address(feeDistributorImpl));

        PresaleManager presaleImpl = new PresaleManager();
        console.log("PresaleManager template:", address(presaleImpl));

        VestingStream vestingImpl = new VestingStream();
        console.log("VestingStream template:", address(vestingImpl));

        LPStaking lpStakingImpl = new LPStaking();
        console.log("LPStaking template:", address(lpStakingImpl));

        // 2. Deploy BoardwalkLPManager (singleton)
        BoardwalkLPManager lpManager = new BoardwalkLPManager(dexFactory, dexRouter, raiseToken);
        console.log("BoardwalkLPManager:", address(lpManager));

        // 3. Deploy BoardwalkFeeCollector (singleton)
        BoardwalkFeeCollector feeCollector = new BoardwalkFeeCollector(owner, raiseToken, dexRouter, treasury, keeper);
        console.log("BoardwalkFeeCollector:", address(feeCollector));

        // 4. Deploy IntegratorFeeCollector (singleton — owner is `owner`; setFactory called below).
        //    The constructor itself validates the integrator/split arrays.
        IntegratorFeeCollector integratorCollector =
            new IntegratorFeeCollector(owner, raiseToken, dexRouter, integratorAddresses, integratorSplits);
        console.log("IntegratorFeeCollector:", address(integratorCollector));

        // 5. Deploy LaunchFactory (singleton — wires everything together).
        LaunchFactory factory = new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenImpl),
                feeDistributorImpl: address(feeDistributorImpl),
                presaleImpl: address(presaleImpl),
                vestingImpl: address(vestingImpl),
                lpStakingImpl: address(lpStakingImpl),
                bwlk: bwlk,
                raiseToken: raiseToken,
                boardwalkRouter: dexRouter,
                boardwalkDexFactory: dexFactory,
                boardwalkLpManager: address(lpManager),
                boardwalkFeeCollector: address(feeCollector),
                integratorCollector: address(integratorCollector),
                integratorBps: integratorBps,
                bwlkBurnAmount: bwlkBurnAmount,
                graduationExpress: graduationExpress,
                graduationAdvanced: graduationAdvanced,
                expressDuration: expressDuration,
                advancedDuration: advancedDuration,
                antiWhaleTaxBps: antiWhaleTaxBps,
                antiWhaleDuration: antiWhaleDuration,
                feeBps: feeBps,
                nftCollection: nftCollection,
                memberLaunchDiscountBps: memberLaunchDiscountBps
            })
        );
        console.log("LaunchFactory:", address(factory));

        // 6. Wire the factory into the integrator collector. One-shot; ownership can be renounced
        //    afterwards if the operator wants to permanently lock the contract.
        // The collector's `owner` is the `owner` param above, which may be different from
        //    `deployer`. If they differ, `setFactory` will be called by `owner` separately
        //    post-deploy. Otherwise we call it here.
        if (deployer == owner) {
            integratorCollector.setFactory(address(factory));
            console.log("IntegratorFeeCollector.setFactory called");
        } else {
            console.log("Owner differs from deployer; owner must call setFactory(factory) post-deploy");
        }

        // 7. Deploy BoostBurn (community ranking), wired to the same membership NFT for discounts.
        BoostBurn boostBurn =
            new BoostBurn(owner, bwlk, epochZero, epochDuration, nftCollection, memberBoostDiscountBps);
        console.log("BoostBurn:", address(boostBurn));

        vm.stopBroadcast();

        // Post-deployment verification
        console.log("\n=== Verification ===");
        require(factory.TOKEN_IMPL() == address(tokenImpl), "tokenImpl mismatch");
        require(factory.RAISE_TOKEN() == raiseToken, "RAISE_TOKEN mismatch");
        require(factory.BWLK() == bwlk, "BWLK mismatch");
        require(factory.BOARDWALK_ROUTER() == dexRouter, "Router mismatch");
        require(factory.BOARDWALK_DEX_FACTORY() == dexFactory, "DEX Factory mismatch");
        require(factory.BOARDWALK_LP_MANAGER() == address(lpManager), "LPManager mismatch");
        require(factory.boardwalkFeeCollector() == address(feeCollector), "FeeCollector mismatch");
        require(factory.INTEGRATOR_COLLECTOR() == address(integratorCollector), "IntegratorCollector mismatch");
        require(factory.antiWhaleTaxBps() == antiWhaleTaxBps, "AntiWhale tax mismatch");
        require(factory.antiWhaleDuration() == antiWhaleDuration, "AntiWhale duration mismatch");
        require(factory.nftCollection() == nftCollection, "Factory NFT mismatch");
        require(integratorCollector.slotCount() == integratorAddresses.length, "Integrator slot count mismatch");
        require(boostBurn.owner() == owner, "BoostBurn owner mismatch");
        require(boostBurn.BWLK() == bwlk, "BoostBurn BWLK mismatch");
        require(boostBurn.nftCollection() == nftCollection, "BoostBurn NFT mismatch");
        if (deployer == owner) {
            require(integratorCollector.factory() == address(factory), "Collector factory wiring mismatch");
        }
        console.log("All verifications passed");
    }
}

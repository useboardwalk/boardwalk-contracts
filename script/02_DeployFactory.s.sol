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

/// @title DeployFactory
/// @notice Deploys all Boardwalk singleton contracts and implementation templates.
/// @dev Deployment order:
///      1. Implementation templates (5 contracts)
///      2. BoardwalkLPManager (singleton)
///      3. BoardwalkFeeCollector (singleton)
///      4. IntegratorFeeCollector (per-chain singleton; frozen integrators[]/splits[])
///      5. LaunchFactory (singleton — wires everything)
///      6. integratorCollector.setFactory(factory) — one-shot to break the chicken-and-egg
contract DeployFactory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address dexFactory = vm.envAddress("DEX_FACTORY");
        address dexRouter = vm.envAddress("DEX_ROUTER");
        address owner = vm.envOr("OWNER", deployer);
        address bmx = vm.envAddress("BMX_ADDRESS");
        address raiseToken = vm.envAddress("RAISE_TOKEN_ADDRESS");
        address treasury = vm.envOr("TREASURY", owner);
        address keeper = vm.envAddress("KEEPER");
        uint256 bmxBurnAmount = vm.envOr("BMX_BURN_AMOUNT", uint256(100e18));
        uint256 graduationExpress = vm.envOr("GRADUATION_EXPRESS", uint256(10 ether));
        uint256 graduationAdvanced = vm.envOr("GRADUATION_ADVANCED", uint256(10 ether));
        uint256 expressDuration = vm.envOr("EXPRESS_DURATION", uint256(24 hours));
        uint256 advancedDuration = vm.envOr("ADVANCED_DURATION", uint256(7 days));
        address nftCollection = vm.envOr("NFT_COLLECTION", address(0));
        uint256 memberLaunchDiscountBps = vm.envOr("MEMBER_LAUNCH_DISCOUNT_BPS", uint256(2500));

        // Anti-whale defaults — preserve previous hardcoded values unless env overrides.
        uint256 antiWhaleTaxBps = vm.envOr("ANTI_WHALE_TAX_BPS", uint256(4000));
        uint256 antiWhaleDuration = vm.envOr("ANTI_WHALE_DURATION", uint256(90 minutes));

        // Frozen per-chain integrator config. Constructor of IntegratorFeeCollector validates
        // length, distinctness, non-zero entries, non-zero splits, and that splits sum to 10000.
        address[] memory integratorAddresses = vm.envAddress("INTEGRATOR_ADDRESSES", ",");
        uint256[] memory integratorSplits = vm.envUint("INTEGRATOR_SPLITS", ",");

        require(owner != address(0), "OWNER required");
        require(bmx != address(0), "BMX_ADDRESS required");
        require(raiseToken != address(0), "RAISE_TOKEN_ADDRESS required");
        require(dexFactory != address(0), "DEX_FACTORY required");
        require(dexRouter != address(0), "DEX_ROUTER required");
        require(treasury != address(0), "TREASURY required");
        require(keeper != address(0), "KEEPER required");

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Boardwalk Factory Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Owner:", owner);
        console.log("Chain id:", block.chainid);

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

        // 4. Per-chain fee defaults + integrator collector deployment.
        //    Conservative chain-id dispatch: unsupported chains revert rather than silently
        //    defaulting to either schedule. Integrator BPS is set as an immutable on the factory
        //    (not in `feeBps`) and CANNOT be adjusted post-deployment. Total stays 115 BPS.
        LaunchFactory.FeeBpsDefaults memory feeBps;
        uint256 integratorBps;
        uint256 cid = block.chainid;
        if (cid == 1) {
            // Ethereum mainnet
            feeBps = LaunchFactory.FeeBpsDefaults({
                issuer: 35,
                boardwalk: 40,
                incentive: 25,
                referrer: 5,
                total: 115
            });
            integratorBps = 15;
        } else if (cid == 8453 || cid == 252 || cid == 2522) {
            // Base (8453), Fraxtal (252), Fraxtal Holesky (2522). Katana chain id TBD.
            feeBps = LaunchFactory.FeeBpsDefaults({
                issuer: 30,
                boardwalk: 35,
                incentive: 23,
                referrer: 5,
                total: 115
            });
            integratorBps = 27;
        } else {
            revert("Unsupported chain id - configure fee schedule explicitly");
        }

        // 5. Deploy IntegratorFeeCollector (singleton — owner is `owner`; setFactory called below).
        //    The constructor itself validates the integrator/split arrays.
        IntegratorFeeCollector integratorCollector =
            new IntegratorFeeCollector(owner, raiseToken, dexRouter, integratorAddresses, integratorSplits);
        console.log("IntegratorFeeCollector:", address(integratorCollector));

        // 6. Deploy LaunchFactory (singleton — wires everything together).
        LaunchFactory factory = new LaunchFactory(
            owner,
            LaunchFactory.DeployParams({
                tokenImpl: address(tokenImpl),
                feeDistributorImpl: address(feeDistributorImpl),
                presaleImpl: address(presaleImpl),
                vestingImpl: address(vestingImpl),
                lpStakingImpl: address(lpStakingImpl),
                bmx: bmx,
                raiseToken: raiseToken,
                boardwalkRouter: dexRouter,
                boardwalkDexFactory: dexFactory,
                boardwalkLpManager: address(lpManager),
                boardwalkFeeCollector: address(feeCollector),
                integratorCollector: address(integratorCollector),
                integratorBps: integratorBps,
                bmxBurnAmount: bmxBurnAmount,
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

        // 7. Wire the factory into the integrator collector. One-shot; ownership can be renounced
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

        vm.stopBroadcast();

        // Post-deployment verification
        console.log("\n=== Verification ===");
        require(factory.TOKEN_IMPL() == address(tokenImpl), "tokenImpl mismatch");
        require(factory.RAISE_TOKEN() == raiseToken, "RAISE_TOKEN mismatch");
        require(factory.BMX() == bmx, "BMX mismatch");
        require(factory.BOARDWALK_ROUTER() == dexRouter, "Router mismatch");
        require(factory.BOARDWALK_DEX_FACTORY() == dexFactory, "DEX Factory mismatch");
        require(factory.BOARDWALK_LP_MANAGER() == address(lpManager), "LPManager mismatch");
        require(factory.boardwalkFeeCollector() == address(feeCollector), "FeeCollector mismatch");
        require(factory.INTEGRATOR_COLLECTOR() == address(integratorCollector), "IntegratorCollector mismatch");
        require(factory.antiWhaleTaxBps() == antiWhaleTaxBps, "AntiWhale tax mismatch");
        require(factory.antiWhaleDuration() == antiWhaleDuration, "AntiWhale duration mismatch");
        if (deployer == owner) {
            require(integratorCollector.factory() == address(factory), "Collector factory wiring mismatch");
        }
        console.log("All verifications passed");
    }
}

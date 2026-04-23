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

/// @title DeployFactory
/// @notice Deploys all Boardwalk singleton contracts and implementation templates
/// @dev Deployment order:
///      1. Implementation templates (5 contracts - used as clone sources)
///      2. BoardwalkLPManager (singleton - needs DEX factory + router)
///      3. BoardwalkFeeCollector (singleton - needs raise token, router, treasury, keeper)
///      4. LaunchFactory (singleton - needs all of the above)
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

        // 2. Deploy BoardwalkLPManager (singleton) — needs RAISE_TOKEN for pair restriction
        BoardwalkLPManager lpManager = new BoardwalkLPManager(dexFactory, dexRouter, raiseToken);
        console.log("BoardwalkLPManager:", address(lpManager));

        // 3. Deploy BoardwalkFeeCollector (singleton)
        BoardwalkFeeCollector feeCollector = new BoardwalkFeeCollector(owner, raiseToken, dexRouter, treasury, keeper);
        console.log("BoardwalkFeeCollector:", address(feeCollector));

        // 4. Deploy LaunchFactory (singleton - wires everything together)
        LaunchFactory.FeeBpsDefaults memory feeBps = LaunchFactory.FeeBpsDefaults({
            issuer: 40, // 0.40%
            boardwalk: 45, // 0.45%
            incentive: 30, // 0.30%
            referrer: 5, // 0.05% (carved from boardwalk)
            integrator: 0,
            total: 115 // 1.15% base tax
        });

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
                bmxBurnAmount: bmxBurnAmount,
                graduationExpress: graduationExpress,
                graduationAdvanced: graduationAdvanced,
                expressDuration: expressDuration,
                advancedDuration: advancedDuration,
                feeBps: feeBps,
                nftCollection: nftCollection,
                memberLaunchDiscountBps: memberLaunchDiscountBps
            })
        );
        console.log("LaunchFactory:", address(factory));

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
        console.log("All verifications passed");
    }
}

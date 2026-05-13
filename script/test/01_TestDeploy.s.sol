// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {BaseTestScript} from "./BaseTestScript.s.sol";
import {IDEXRouter} from "src/interfaces/IDEXRouter.sol";
import {BoardwalkToken} from "src/core/BoardwalkToken.sol";
import {FeeDistributor} from "src/core/FeeDistributor.sol";
import {PresaleManager} from "src/core/PresaleManager.sol";
import {VestingStream} from "src/core/VestingStream.sol";
import {LPStaking} from "src/core/LPStaking.sol";
import {BoardwalkLPManager} from "src/core/BoardwalkLPManager.sol";
import {BoardwalkFeeCollector} from "src/core/BoardwalkFeeCollector.sol";
import {IntegratorFeeCollector} from "src/core/IntegratorFeeCollector.sol";
import {LaunchFactory} from "src/core/LaunchFactory.sol";

contract TestDeployScript is BaseTestScript {
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    function _scriptName() internal pure override returns (string memory) {
        return "TestDeployScript";
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address owner = vm.envOr("OWNER", deployer);
        address bmx = vm.envAddress("BMX_ADDRESS");
        address raiseToken = vm.envOr("RAISE_TOKEN_ADDRESS", BASE_WETH);
        address feeToSetter = vm.envOr("FEE_TO_SETTER", owner);
        address treasury = vm.envOr("TREASURY", owner);
        address keeper = vm.envAddress("KEEPER_ADDRESS");

        uint256 graduationExpress = vm.envOr("GRADUATION_EXPRESS", uint256(0.0001 ether));
        uint256 graduationAdvanced = vm.envOr("GRADUATION_ADVANCED", uint256(0.0001 ether));
        uint256 expressDuration = vm.envOr("EXPRESS_DURATION", uint256(24 hours));
        uint256 advancedDuration = vm.envOr("ADVANCED_DURATION", uint256(7 days));
        uint256 bmxBurnTarget = vm.envOr("BMX_BURN_AMOUNT", uint256(1e18));

        require(owner != address(0), "OWNER required");
        require(bmx != address(0), "BMX_ADDRESS required");
        require(raiseToken != address(0), "RAISE_TOKEN_ADDRESS required");
        require(feeToSetter != address(0), "FEE_TO_SETTER required");
        require(treasury != address(0), "TREASURY required");

        _initTxTracking();
        vm.startBroadcast(deployerPrivateKey);

        address dexFactory =
            vm.deployCode("src/dex/core/UniswapV2Factory.sol:UniswapV2Factory", abi.encode(feeToSetter));
        _recordTx("Deploy DEX Factory");

        address dexRouter = vm.deployCode(
            "src/dex/periphery/UniswapV2Router02.sol:UniswapV2Router02", abi.encode(dexFactory, BASE_WETH)
        );
        _recordTx("Deploy DEX Router");

        require(IDEXRouter(dexRouter).factory() == dexFactory, "Router-Factory mismatch");

        BoardwalkToken tokenImpl = new BoardwalkToken();
        _recordTx("Deploy BoardwalkToken template");

        FeeDistributor feeDistributorImpl = new FeeDistributor();
        _recordTx("Deploy FeeDistributor template");

        PresaleManager presaleImpl = new PresaleManager();
        _recordTx("Deploy PresaleManager template");

        VestingStream vestingImpl = new VestingStream();
        _recordTx("Deploy VestingStream template");

        LPStaking lpStakingImpl = new LPStaking();
        _recordTx("Deploy LPStaking template");

        BoardwalkLPManager lpManager = new BoardwalkLPManager(dexFactory, dexRouter, raiseToken);
        _recordTx("Deploy BoardwalkLPManager");

        BoardwalkFeeCollector feeCollector = new BoardwalkFeeCollector(owner, raiseToken, dexRouter, treasury, keeper);
        _recordTx("Deploy BoardwalkFeeCollector");

        // Single-integrator chain config: 100% to `owner`. Constructor validates the arrays.
        address[] memory integratorAddresses = new address[](1);
        integratorAddresses[0] = owner;
        uint256[] memory integratorSplits = new uint256[](1);
        integratorSplits[0] = 10_000;

        IntegratorFeeCollector integratorCollector =
            new IntegratorFeeCollector(owner, raiseToken, dexRouter, integratorAddresses, integratorSplits);
        _recordTx("Deploy IntegratorFeeCollector");

        LaunchFactory.FeeBpsDefaults memory feeBps = LaunchFactory.FeeBpsDefaults({
            issuer: 30,
            boardwalk: 35,
            incentive: 23,
            referrer: 5,
            total: 115
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
                integratorCollector: address(integratorCollector),
                integratorBps: 27,
                bmxBurnAmount: bmxBurnTarget,
                graduationExpress: graduationExpress,
                graduationAdvanced: graduationAdvanced,
                expressDuration: expressDuration,
                advancedDuration: advancedDuration,
                antiWhaleTaxBps: 4000,
                antiWhaleDuration: 90 minutes,
                feeBps: feeBps,
                nftCollection: address(0),
                memberLaunchDiscountBps: 0
            })
        );
        _recordTx("Deploy LaunchFactory");

        // Wire the factory into the collector when deployer == owner; otherwise owner must do it.
        if (deployer == owner) {
            integratorCollector.setFactory(address(factory));
            _recordTx("IntegratorFeeCollector.setFactory");
        }

        vm.stopBroadcast();

        console.log("=== TEST DEPLOYMENT ADDRESSES ===");
        console.log("DEX_FACTORY:", dexFactory);
        console.log("DEX_ROUTER:", dexRouter);
        console.log("TOKEN_TEMPLATE:", address(tokenImpl));
        console.log("FEE_DISTRIBUTOR_TEMPLATE:", address(feeDistributorImpl));
        console.log("PRESALE_TEMPLATE:", address(presaleImpl));
        console.log("VESTING_TEMPLATE:", address(vestingImpl));
        console.log("LP_STAKING_TEMPLATE:", address(lpStakingImpl));
        console.log("LP_MANAGER:", address(lpManager));
        console.log("FEE_COLLECTOR:", address(feeCollector));
        console.log("INTEGRATOR_COLLECTOR:", address(integratorCollector));
        console.log("LAUNCH_FACTORY:", address(factory));
        console.log("BMX_BURN_AMOUNT:", factory.bmxBurnAmount());

        _printTxSummary();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTestScript} from "./BaseTestScript.s.sol";
import {LaunchFactory} from "src/core/LaunchFactory.sol";
import {PresaleManager} from "src/core/PresaleManager.sol";
import {IPresaleManager} from "src/interfaces/IPresaleManager.sol";

interface IPresaleManagerLive is IPresaleManager {
    function token() external view returns (address);
    function feeDistributor() external view returns (address);
    function lpStaking() external view returns (address);
}

contract TestAdvancedLaunchScript is BaseTestScript {
    function _scriptName() internal pure override returns (string memory) {
        return "TestAdvancedLaunchScript";
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address factoryAddress = vm.envAddress("LAUNCH_FACTORY");
        LaunchFactory factory = LaunchFactory(factoryAddress);
        address raiseToken = vm.envOr("RAISE_TOKEN_ADDRESS", factory.RAISE_TOKEN());
        address bmx = factory.BMX();
        uint256 bmxBurnAmount = factory.bmxBurnAmount();
        address referrer = vm.envOr("ADV_REFERRER", deployer);
        address feeRecipientTwo = vm.envOr("ADV_FEE_RECIPIENT_TWO", deployer);
        address vestingRecipientOne = vm.envOr("ADV_VESTING_RECIPIENT_ONE", deployer);
        address vestingRecipientTwo = vm.envOr("ADV_VESTING_RECIPIENT_TWO", deployer);
        address existingPresaleManager = vm.envOr("ADVANCED_PRESALE_MANAGER", address(0));

        uint256 presalePercent = vm.envOr("ADV_PRESALE_PERCENT", uint256(3000));
        uint256 contributionAmount = vm.envOr("ADV_CONTRIBUTION", uint256(0.00012 ether));

        require(raiseToken != address(0), "RAISE_TOKEN_ADDRESS required");
        require(referrer != address(0), "ADV_REFERRER required");
        require(feeRecipientTwo != address(0), "ADV_FEE_RECIPIENT_TWO required");
        require(vestingRecipientOne != address(0) && vestingRecipientTwo != address(0), "Vesting recipients required");
        require(contributionAmount > 0, "ADV_CONTRIBUTION must be > 0");

        address tokenAddr;
        address presaleManagerAddr;
        address feeDistributorAddr;
        address lpStakingAddr;
        bool createdInThisRun;

        _initTxTracking();
        vm.startBroadcast(deployerPrivateKey);

        if (existingPresaleManager == address(0)) {
            createdInThisRun = true;

            address[] memory feeRecipients = new address[](2);
            feeRecipients[0] = deployer;
            feeRecipients[1] = feeRecipientTwo;
            uint256[] memory feeSplits = new uint256[](2);
            feeSplits[0] = 7000;
            feeSplits[1] = 3000;

            address[] memory vestingRecipients = new address[](2);
            vestingRecipients[0] = vestingRecipientOne;
            vestingRecipients[1] = vestingRecipientTwo;
            uint256[] memory vestingPercents = new uint256[](2);
            vestingPercents[0] = 6000;
            vestingPercents[1] = 4000;

            string[] memory feeLabels = new string[](2);
            feeLabels[0] = "fee1";
            feeLabels[1] = "fee2";
            string[] memory vestLabels = new string[](2);
            vestLabels[0] = "vest1";
            vestLabels[1] = "vest2";

            LaunchFactory.LaunchConfig memory advancedConfig = LaunchFactory.LaunchConfig({
                name: vm.envOr("ADV_NAME", string("Boardwalk Advanced Test")),
                ticker: vm.envOr("ADV_TICKER", string("BWADV")),
                category: vm.envOr("ADV_CATEGORY", string("Testing")),
                description: vm.envOr("ADV_DESCRIPTION", string("Advanced test launch on Base mainnet")),
                path: LaunchFactory.LaunchPath.ADVANCED,
                presalePercent: presalePercent,
                vestingRecipients: vestingRecipients,
                vestingPercents: vestingPercents,
                vestingLabels: vestLabels,
                referrer: referrer,
                issuerFeeRecipients: feeRecipients,
                issuerFeeSplits: feeSplits,
                issuerFeeLabels: feeLabels
            });

            if (bmxBurnAmount > 0) {
                require(IERC20(bmx).balanceOf(deployer) >= bmxBurnAmount, "Insufficient BMX for burn");
                IERC20(bmx).approve(factoryAddress, bmxBurnAmount);
                _recordTx("BMX.approve");
            }

            tokenAddr = factory.createLaunch(advancedConfig);
            _recordTx("LaunchFactory.createLaunch");

            LaunchFactory.LaunchInfo memory info;
            (
                info.token,
                info.feeDistributor,
                info.presaleManager,
                info.vestingStream,
                info.lpStaking,
                info.issuer,
                info.path,
                info.createdAt
            ) = factory.launches(tokenAddr);
            presaleManagerAddr = info.presaleManager;
            feeDistributorAddr = info.feeDistributor;
            lpStakingAddr = info.lpStaking;
        } else {
            presaleManagerAddr = existingPresaleManager;
            IPresaleManagerLive existing = IPresaleManagerLive(existingPresaleManager);
            tokenAddr = existing.token();
            feeDistributorAddr = existing.feeDistributor();
            lpStakingAddr = existing.lpStaking();
        }

        uint256 presaleStart = IPresaleManager(presaleManagerAddr).presaleStart();
        if (block.timestamp >= presaleStart) {
            IERC20(raiseToken).approve(presaleManagerAddr, contributionAmount);
            _recordTx("RaiseToken.approve");

            IPresaleManager(presaleManagerAddr).contribute(contributionAmount);
            _recordTx("PresaleManager.contribute");
        } else {
            console.log("Advanced presale has not started yet.");
            console.log("Presale start:", presaleStart);
            console.log("Current time :", block.timestamp);
            console.log("Rerun this script with ADVANCED_PRESALE_MANAGER once start time is reached.");
        }

        vm.stopBroadcast();

        PresaleManager pm = PresaleManager(presaleManagerAddr);
        uint256 seedableAt = pm.presaleEnd() + pm.SEED_DELAY();
        console.log("ADVANCED_TOKEN:", tokenAddr);
        console.log("ADVANCED_PRESALE_MANAGER:", presaleManagerAddr);
        console.log("ADVANCED_FEE_DISTRIBUTOR:", feeDistributorAddr);
        console.log("ADVANCED_LP_STAKING:", lpStakingAddr);
        console.log("ADV_REFERRER:", referrer);
        if (createdInThisRun) {
            uint256 seedWait = pm.ADVANCED_START_DELAY() + factory.advancedDuration() + pm.SEED_DELAY();
            console.log(
                "Fresh Advanced launch: wait",
                seedWait,
                "seconds (ADVANCED_START_DELAY + advancedDuration + SEED_DELAY) before 05"
            );
        }
        if (block.timestamp < seedableAt) {
            console.log("Earliest seed time:", seedableAt);
        }
        console.log("After seed, wait", pm.CLIFF_DURATION(), "seconds before presale/vesting claims");
        console.log("Run 05_TestAdvancedSeed.s.sol once seed time is reached.");

        _printTxSummary();
    }
}

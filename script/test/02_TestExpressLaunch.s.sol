// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTestScript} from "./BaseTestScript.s.sol";
import {LaunchFactory} from "src/core/LaunchFactory.sol";
import {IPresaleManager} from "src/interfaces/IPresaleManager.sol";

contract TestExpressLaunchScript is BaseTestScript {
    function _scriptName() internal pure override returns (string memory) {
        return "TestExpressLaunchScript";
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address factoryAddress = vm.envAddress("LAUNCH_FACTORY");
        LaunchFactory factory = LaunchFactory(factoryAddress);
        address raiseToken = vm.envOr("RAISE_TOKEN_ADDRESS", factory.RAISE_TOKEN());
        address bmx = factory.BMX();
        uint256 bmxBurnAmount = factory.bmxBurnAmount();

        uint256 contributionOne = vm.envOr("EXPRESS_CONTRIBUTION_ONE", uint256(0.00006 ether));
        uint256 contributionTwo = vm.envOr("EXPRESS_CONTRIBUTION_TWO", uint256(0.00006 ether));

        require(raiseToken != address(0), "RAISE_TOKEN_ADDRESS required");
        require(contributionOne > 0 && contributionTwo > 0, "Contributions must be > 0");

        address[] memory feeRecipients = new address[](1);
        feeRecipients[0] = deployer;
        uint256[] memory feeSplits = new uint256[](1);
        feeSplits[0] = 10_000;

        string[] memory feeLabels = new string[](1);
        feeLabels[0] = "issuer";

        LaunchFactory.LaunchConfig memory expressConfig = LaunchFactory.LaunchConfig({
            name: vm.envOr("EXPRESS_NAME", string("Boardwalk Express Test")),
            ticker: vm.envOr("EXPRESS_TICKER", string("BWEXP")),
            category: vm.envOr("EXPRESS_CATEGORY", string("Testing")),
            description: vm.envOr("EXPRESS_DESCRIPTION", string("Express test launch on Base mainnet")),
            path: LaunchFactory.LaunchPath.EXPRESS,
            presalePercent: 5000,
            vestingRecipients: new address[](0),
            vestingPercents: new uint256[](0),
            vestingLabels: new string[](0),
            referrer: address(0),
            integrator: address(0),
            issuerFeeRecipients: feeRecipients,
            issuerFeeSplits: feeSplits,
            issuerFeeLabels: feeLabels
        });

        _initTxTracking();
        vm.startBroadcast(deployerPrivateKey);

        if (bmxBurnAmount > 0) {
            require(IERC20(bmx).balanceOf(deployer) >= bmxBurnAmount, "Insufficient BMX for burn");
            IERC20(bmx).approve(factoryAddress, bmxBurnAmount);
            _recordTx("BMX.approve");
        }

        address tokenAddr = factory.createLaunch(expressConfig);
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

        IERC20(raiseToken).approve(info.presaleManager, contributionOne + contributionTwo);
        _recordTx("RaiseToken.approve");

        IPresaleManager(info.presaleManager).contribute(contributionOne);
        _recordTx("PresaleManager.contribute #1");

        IPresaleManager(info.presaleManager).contribute(contributionTwo);
        _recordTx("PresaleManager.contribute #2");

        vm.stopBroadcast();

        console.log("EXPRESS_TOKEN:", tokenAddr);
        console.log("EXPRESS_PRESALE_MANAGER:", info.presaleManager);
        console.log("EXPRESS_FEE_DISTRIBUTOR:", info.feeDistributor);
        console.log("EXPRESS_LP_STAKING:", info.lpStaking);
        console.log("Wait ~66 minutes (5 min presale + 1 hr seed delay), then run 03_TestExpressSeed.s.sol");

        _printTxSummary();
    }
}

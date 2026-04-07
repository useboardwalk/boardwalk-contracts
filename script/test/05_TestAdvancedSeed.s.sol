// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseTestScript} from "./BaseTestScript.s.sol";
import {LaunchFactory} from "src/core/LaunchFactory.sol";
import {IDEXRouter} from "src/interfaces/IDEXRouter.sol";
import {IDEXFactory} from "src/interfaces/IDEXFactory.sol";
import {IPresaleManager} from "src/interfaces/IPresaleManager.sol";
import {IFeeDistributor} from "src/interfaces/IFeeDistributor.sol";

interface IPresaleManagerLive is IPresaleManager {
    function token() external view returns (address);
    function feeDistributor() external view returns (address);
    function router() external view returns (address);
    function raiseToken() external view returns (address);
    function dexFactory() external view returns (address);
}

interface IFeeDistributorLive is IFeeDistributor {
    function referrer() external view returns (address);
}

contract TestAdvancedSeedScript is BaseTestScript {
    using SafeERC20 for IERC20;

    function _scriptName() internal pure override returns (string memory) {
        return "TestAdvancedSeedScript";
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address presaleManagerAddr = vm.envOr("ADVANCED_PRESALE_MANAGER", address(0));
        if (presaleManagerAddr == address(0)) {
            address factoryAddress = vm.envOr("LAUNCH_FACTORY", address(0));
            address tokenAddress = vm.envOr("ADVANCED_TOKEN", address(0));
            require(
                factoryAddress != address(0) && tokenAddress != address(0),
                "Need ADVANCED_PRESALE_MANAGER or factory+token"
            );

            LaunchFactory factory = LaunchFactory(factoryAddress);
            (,, presaleManagerAddr,,,,,) = factory.launches(tokenAddress);
            require(presaleManagerAddr != address(0), "Could not resolve presale manager from factory.launches()");
        }

        IPresaleManagerLive presale = IPresaleManagerLive(presaleManagerAddr);

        address token = presale.token();
        address feeDistributor = presale.feeDistributor();
        address router = presale.router();
        address raiseToken = presale.raiseToken();
        address dexFactory = presale.dexFactory();

        address recipientOne = vm.envOr("TEST_RECIPIENT_ONE", address(0x6000000000000000000000000000000000000006));
        address recipientTwo = vm.envOr("TEST_RECIPIENT_TWO", address(0x7000000000000000000000000000000000000007));
        uint256 buyAmount = vm.envOr("ADV_BUY_RAISE_AMOUNT", uint256(0.00003 ether));
        uint256 deadlineWindow = vm.envOr("DEADLINE_WINDOW", uint256(20 minutes));

        require(token != address(0), "Invalid token");
        require(feeDistributor != address(0), "Invalid fee distributor");
        require(router != address(0), "Invalid router");
        require(raiseToken != address(0), "Invalid raise token");
        require(recipientOne != address(0) && recipientTwo != address(0), "Recipients required");
        require(buyAmount > 0, "ADV_BUY_RAISE_AMOUNT must be > 0");

        _initTxTracking();
        vm.startBroadcast(deployerPrivateKey);

        presale.seedLiquidity();
        _recordTx("PresaleManager.seedLiquidity");

        console.log("NOTE: Post-seed transfers are in anti-whale window.");
        console.log("Tax can be high (up to ~40%%) and decays over ~90 minutes.");

        IERC20(raiseToken).approve(router, buyAmount);
        _recordTx("RaiseToken.approve");

        address[] memory buyPath = new address[](2);
        buyPath[0] = raiseToken;
        buyPath[1] = token;
        IDEXRouter(router).swapExactTokensForTokens(buyAmount, 0, buyPath, deployer, block.timestamp + deadlineWindow);
        _recordTx("Router.swapExactTokensForTokens (buy token)");

        uint256 tokenBalance = IERC20(token).balanceOf(deployer);
        require(tokenBalance > 3, "Not enough tokens after buy");

        uint256 transferOne = vm.envOr("ADV_TRANSFER_ONE", tokenBalance / 6);
        uint256 transferTwo = vm.envOr("ADV_TRANSFER_TWO", tokenBalance / 7);
        if (transferOne == 0 || transferTwo == 0 || transferOne + transferTwo >= tokenBalance) {
            transferOne = tokenBalance / 10;
            transferTwo = tokenBalance / 11;
        }
        require(transferOne > 0 && transferTwo > 0, "Transfer amounts too small");

        IERC20(token).safeTransfer(recipientOne, transferOne);
        _recordTx("BoardwalkToken.transfer #1");

        IERC20(token).safeTransfer(recipientTwo, transferTwo);
        _recordTx("BoardwalkToken.transfer #2");

        uint256 issuerClaimIdx = vm.envOr("ADV_ISSUER_CLAIM_IDX", uint256(0));
        uint256 claimableIssuer = IFeeDistributor(feeDistributor).claimableAmount(issuerClaimIdx);
        address issuerRecipient = IFeeDistributor(feeDistributor).issuerRecipients(issuerClaimIdx);

        if (issuerRecipient == deployer && claimableIssuer > 0) {
            IFeeDistributor(feeDistributor).claimAsRaiseToken(issuerClaimIdx, 0, block.timestamp + deadlineWindow);
            _recordTx("FeeDistributor.claimAsRaiseToken");
        } else {
            console.log("Skipping issuer claim: no claimable amount yet or deployer is not selected recipient.");
        }

        address referrer = IFeeDistributorLive(feeDistributor).referrer();
        if (referrer == deployer) {
            IFeeDistributor(feeDistributor).claimReferrerFees();
            _recordTx("FeeDistributor.claimReferrerFees");
        } else {
            uint256 referrerPrivateKey = vm.envOr("REFERRER_PRIVATE_KEY", uint256(0));
            require(referrerPrivateKey != 0, "REFERRER_PRIVATE_KEY required for referrer claim");
            require(vm.addr(referrerPrivateKey) == referrer, "REFERRER_PRIVATE_KEY does not match referrer");

            vm.stopBroadcast();
            vm.startBroadcast(referrerPrivateKey);
            IFeeDistributor(feeDistributor).claimReferrerFees();
            _recordTx("FeeDistributor.claimReferrerFees");
        }

        vm.stopBroadcast();

        address pair = IDEXFactory(dexFactory).getPair(token, raiseToken);
        console.log("ADVANCED_TOKEN:", token);
        console.log("ADVANCED_PRESALE_MANAGER:", presaleManagerAddr);
        console.log("ADVANCED_FEE_DISTRIBUTOR:", feeDistributor);
        console.log("ADVANCED_PAIR:", pair);
        console.log("ADV_REFERRER:", referrer);

        _printTxSummary();
    }
}

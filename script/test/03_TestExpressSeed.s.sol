// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseTestScript} from "./BaseTestScript.s.sol";
import {LaunchFactory} from "src/core/LaunchFactory.sol";
import {IDEXRouter} from "src/interfaces/IDEXRouter.sol";
import {IDEXFactory} from "src/interfaces/IDEXFactory.sol";
import {ILPStaking} from "src/interfaces/ILPStaking.sol";
import {IPresaleManager} from "src/interfaces/IPresaleManager.sol";

interface IPresaleManagerLive is IPresaleManager {
    function token() external view returns (address);
    function feeDistributor() external view returns (address);
    function lpStaking() external view returns (address);
    function router() external view returns (address);
    function raiseToken() external view returns (address);
    function dexFactory() external view returns (address);
}

contract TestExpressSeedScript is BaseTestScript {
    using SafeERC20 for IERC20;

    function _scriptName() internal pure override returns (string memory) {
        return "TestExpressSeedScript";
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address presaleManagerAddr = vm.envOr("EXPRESS_PRESALE_MANAGER", address(0));
        if (presaleManagerAddr == address(0)) {
            address factoryAddress = vm.envOr("LAUNCH_FACTORY", address(0));
            address tokenAddress = vm.envOr("EXPRESS_TOKEN", address(0));
            require(
                factoryAddress != address(0) && tokenAddress != address(0),
                "Need EXPRESS_PRESALE_MANAGER or factory+token"
            );

            LaunchFactory factory = LaunchFactory(factoryAddress);
            (,, presaleManagerAddr,,,,,) = factory.launches(tokenAddress);
            require(presaleManagerAddr != address(0), "Could not resolve presale manager from factory.launches()");
        }

        IPresaleManagerLive presale = IPresaleManagerLive(presaleManagerAddr);

        address token = presale.token();
        address feeDistributor = presale.feeDistributor();
        address lpStaking = presale.lpStaking();
        address router = presale.router();
        address raiseToken = presale.raiseToken();
        address dexFactory = presale.dexFactory();

        address recipientOne = vm.envOr("TEST_RECIPIENT_ONE", address(0x1000000000000000000000000000000000000001));
        address recipientTwo = vm.envOr("TEST_RECIPIENT_TWO", address(0x2000000000000000000000000000000000000002));
        uint256 buyAmount = vm.envOr("EXPRESS_BUY_RAISE_AMOUNT", uint256(0.00003 ether));
        uint256 lpRaiseAmount = vm.envOr("EXPRESS_LP_RAISE_AMOUNT", uint256(0.00001 ether));
        uint256 deadlineWindow = vm.envOr("DEADLINE_WINDOW", uint256(20 minutes));

        require(token != address(0), "Invalid token");
        require(router != address(0), "Invalid router");
        require(raiseToken != address(0), "Invalid raise token");
        require(lpStaking != address(0), "Invalid LPStaking");
        require(recipientOne != address(0) && recipientTwo != address(0), "Recipients required");
        require(buyAmount > 0 && lpRaiseAmount > 0, "Amounts must be > 0");

        _initTxTracking();
        vm.startBroadcast(deployerPrivateKey);

        presale.seedLiquidity();
        _recordTx("PresaleManager.seedLiquidity");

        console.log("NOTE: Post-seed transfers are in anti-whale window.");
        console.log("Tax can be high (up to ~40%%) and decays over ~90 minutes.");

        IERC20(raiseToken).approve(router, buyAmount + lpRaiseAmount);
        _recordTx("RaiseToken.approve");

        address[] memory buyPath = new address[](2);
        buyPath[0] = raiseToken;
        buyPath[1] = token;
        IDEXRouter(router).swapExactTokensForTokens(buyAmount, 0, buyPath, deployer, block.timestamp + deadlineWindow);
        _recordTx("Router.swapExactTokensForTokens (buy token)");

        uint256 tokenBalance = IERC20(token).balanceOf(deployer);
        require(tokenBalance > 3, "Not enough tokens after buy");

        uint256 transferOne = vm.envOr("EXPRESS_TRANSFER_ONE", tokenBalance / 6);
        uint256 transferTwo = vm.envOr("EXPRESS_TRANSFER_TWO", tokenBalance / 7);
        if (transferOne == 0 || transferTwo == 0 || transferOne + transferTwo >= tokenBalance) {
            transferOne = tokenBalance / 10;
            transferTwo = tokenBalance / 11;
        }
        require(transferOne > 0 && transferTwo > 0, "Transfer amounts too small");

        IERC20(token).safeTransfer(recipientOne, transferOne);
        _recordTx("BoardwalkToken.transfer #1");

        IERC20(token).safeTransfer(recipientTwo, transferTwo);
        _recordTx("BoardwalkToken.transfer #2");

        uint256 remainingToken = IERC20(token).balanceOf(deployer);
        uint256 lpTokenAmount = vm.envOr("EXPRESS_LP_TOKEN_AMOUNT", remainingToken / 2);
        if (lpTokenAmount == 0 || lpTokenAmount > remainingToken) {
            lpTokenAmount = remainingToken;
        }
        require(lpTokenAmount > 0, "No token balance for LP add");

        IERC20(token).approve(router, lpTokenAmount);
        _recordTx("BoardwalkToken.approve Router");

        IDEXRouter(router)
            .addLiquidity(
                token, raiseToken, lpTokenAmount, lpRaiseAmount, 0, 0, deployer, block.timestamp + deadlineWindow
            );
        _recordTx("Router.addLiquidity");

        address pair = IDEXFactory(dexFactory).getPair(token, raiseToken);
        require(pair != address(0), "Pair not found");

        uint256 lpBalance = IERC20(pair).balanceOf(deployer);
        require(lpBalance > 0, "No LP tokens received");

        IERC20(pair).approve(lpStaking, lpBalance);
        _recordTx("LPToken.approve LPStaking");

        ILPStaking(lpStaking).stake(lpBalance);
        _recordTx("LPStaking.stake");

        vm.stopBroadcast();

        console.log("EXPRESS_TOKEN:", token);
        console.log("EXPRESS_PRESALE_MANAGER:", presaleManagerAddr);
        console.log("EXPRESS_FEE_DISTRIBUTOR:", feeDistributor);
        console.log("EXPRESS_LP_STAKING:", lpStaking);
        console.log("EXPRESS_PAIR:", pair);

        _printTxSummary();
    }
}

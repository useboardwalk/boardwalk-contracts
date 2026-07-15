// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployRevenueBridging} from "script/06_DeployRevenueBridging.s.sol";
import {CrossChainConfig} from "script/CrossChainConfig.sol";

/// @title RevenueBridgingDeployGuardTest
/// @notice The Ethereum revenue lane is retired for the BWLK era (Ethereum is the governance home;
///         a Base-pinned bridger there would divert the hub's own revenue). The deploy script must
///         hard-revert on chainId 1 before reading any env or broadcasting.
contract RevenueBridgingDeployGuardTest is Test {
    function test_RevertWhen_DeployingTheRetiredEthereumLane() public {
        DeployRevenueBridging deployScript = new DeployRevenueBridging();
        vm.chainId(CrossChainConfig.CHAIN_ETHEREUM);
        vm.expectRevert(DeployRevenueBridging.EthereumLaneRetired.selector);
        deployScript.run();
    }
}

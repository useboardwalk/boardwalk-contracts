// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {CrossChainConfig} from "script/CrossChainConfig.sol";

/// @title RevenueBridgingDeployGuardTest
/// @notice Ethereum is the revenue hub (its FeeCollector's vault feeds the BWLK GovernanceVoter),
///         so it must never have a bridging lane: a lane there would ship the hub's own revenue
///         away and starve the voter's 90% governance budget. The lane config is the structural
///         guard — every lane resolver must revert for chainId 1, and resolve for each source.
contract RevenueBridgingDeployGuardTest is Test {
    function test_RevertWhen_ResolvingAnEthereumLane() public {
        uint256 hub = CrossChainConfig.CHAIN_ETHEREUM;
        bytes memory err = abi.encodeWithSelector(CrossChainConfig.UnsupportedChainId.selector, hub);

        vm.expectRevert(err);
        this.lifiDiamond(hub);
        vm.expectRevert(err);
        this.lifiSelector(hub);
        vm.expectRevert(err);
        this.hasSourceSwaps(hub);
        vm.expectRevert(err);
        this.laneRaiseToken(hub);
    }

    function test_LaneConfigResolvesForEverySourceChain() public pure {
        uint256[3] memory sources =
            [CrossChainConfig.CHAIN_BASE, CrossChainConfig.CHAIN_ARBITRUM, CrossChainConfig.CHAIN_ROBINHOOD];
        for (uint256 i = 0; i < sources.length; i++) {
            assertTrue(CrossChainConfig.lifiDiamond(sources[i]) != address(0), "diamond resolves");
            assertEq(
                CrossChainConfig.lifiSelector(sources[i]), CrossChainConfig.ACROSS_V4_SELECTOR, "pure Across V4 lane"
            );
            assertFalse(CrossChainConfig.hasSourceSwaps(sources[i]), "no source swaps");
            assertTrue(CrossChainConfig.laneRaiseToken(sources[i]) != address(0), "raise token resolves");
        }
    }

    /* ---------------- external wrappers so expectRevert catches library reverts ---------------- */

    function lifiDiamond(
        uint256 chainId
    ) external pure returns (address) {
        return CrossChainConfig.lifiDiamond(chainId);
    }

    function lifiSelector(
        uint256 chainId
    ) external pure returns (bytes4) {
        return CrossChainConfig.lifiSelector(chainId);
    }

    function hasSourceSwaps(
        uint256 chainId
    ) external pure returns (bool) {
        return CrossChainConfig.hasSourceSwaps(chainId);
    }

    function laneRaiseToken(
        uint256 chainId
    ) external pure returns (address) {
        return CrossChainConfig.laneRaiseToken(chainId);
    }
}

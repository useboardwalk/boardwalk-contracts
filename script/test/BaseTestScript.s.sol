// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

abstract contract BaseTestScript is Script {
    string[] internal _txLabels;
    bytes32[] internal _txHashes;
    uint256 internal _seenBroadcastCount;

    function _scriptName() internal pure virtual returns (string memory);

    function _initTxTracking() internal {
        VmSafe.BroadcastTxSummary[] memory existing = _getBroadcastsSafe();
        _seenBroadcastCount = existing.length;
    }

    function _recordTx(
        string memory label
    ) internal {
        VmSafe.BroadcastTxSummary[] memory all = _getBroadcastsSafe();
        bytes32 txHash;

        if (all.length > _seenBroadcastCount) {
            txHash = all[0].txHash;
            _seenBroadcastCount = all.length;
        } else {
            txHash = bytes32(0);
            console.log("WARNING: could not capture tx hash for:");
            console.log(label);
        }

        _txLabels.push(label);
        _txHashes.push(txHash);
    }

    function _printTxSummary() internal view {
        console.log("=== TX SUMMARY ===");

        uint256 len = _txHashes.length;
        for (uint256 i = 0; i < len; i++) {
            console.log(string.concat("TX ", vm.toString(i + 1), " [", _txLabels[i], "] : ", vm.toString(_txHashes[i])));
        }

        console.log(string.concat("=== Look up on https://", _explorerHost(block.chainid), "/tx/<hash> for events ==="));
    }

    function _explorerHost(
        uint256 chainId
    ) internal pure returns (string memory) {
        if (chainId == 1) return "etherscan.io";
        if (chainId == 8453) return "basescan.org";
        if (chainId == 252) return "fraxscan.com";
        if (chainId == 747474) return "katanascan.com";
        if (chainId == 57073) return "explorer.inkonchain.com";
        return "block explorer";
    }

    function _getBroadcastsSafe() internal view returns (VmSafe.BroadcastTxSummary[] memory summaries) {
        try vm.getBroadcasts(_scriptName(), uint64(block.chainid)) returns (VmSafe.BroadcastTxSummary[] memory txs) {
            return txs;
        } catch {
            return new VmSafe.BroadcastTxSummary[](0);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTestScript} from "./BaseTestScript.s.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";

/// @title TestGovernanceVoteAndExecute - Exercise the governance lifecycle on a test deployment
/// @notice Supports two wallets: a VOTER (sbfBMX holder) and a KEEPER (deployer/owner).
///         Runs through: vote → wait epoch → finalize → execute for each option.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY — keeper/owner key from 06_TestGovernanceDeploy
///   GOVERNANCE_VOTER     — GovernanceVoter contract address
///
/// Optional env:
///   VOTER_PRIVATE_KEY — sbfBMX holder key for voting (defaults to DEPLOYER_PRIVATE_KEY)
///   VOTE_OPTION       — 1=Treasury, 2=BuyBurnBMX, 3=BuyBurnLP, 4=Participation (default: 1)
///   REVENUE_AMOUNT    — WETH to send as simulated revenue before finalize (default: 0.0001 ether)
///   ACTION            — "vote", "finalize", "execute", "forceExecute", or "all" (default: "all")
contract TestGovernanceVoteAndExecuteScript is BaseTestScript {
    function _scriptName() internal pure override returns (string memory) {
        return "TestGovernanceVoteAndExecuteScript";
    }

    function run() external {
        uint256 keeperPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 voterPrivateKey = vm.envOr("VOTER_PRIVATE_KEY", keeperPrivateKey);
        address keeperAddr = vm.addr(keeperPrivateKey);
        address voterAddr = vm.addr(voterPrivateKey);

        GovernanceVoter voter = GovernanceVoter(payable(vm.envAddress("GOVERNANCE_VOTER")));
        string memory action = vm.envOr("ACTION", string("all"));
        uint8 voteOption = uint8(vm.envOr("VOTE_OPTION", uint256(1)));
        uint256 revenueAmount = vm.envOr("REVENUE_AMOUNT", uint256(0.0001 ether));

        uint256 currentEpoch = voter.currentEpoch();
        uint256 epochDuration = voter.EPOCH_DURATION();
        uint256 epochZero = voter.EPOCH_ZERO();

        console.log("=== GOVERNANCE STATE ===");
        console.log("Current epoch:", currentEpoch);
        console.log("Epoch duration:", epochDuration, "seconds");
        console.log("Block timestamp:", block.timestamp);
        console.log("Next epoch starts at:", epochZero + (currentEpoch + 1) * epochDuration);
        console.log("Keeper:", keeperAddr);
        console.log("Voter:", voterAddr);
        console.log("WETH balance:", IERC20(voter.WETH()).balanceOf(address(voter)));

        // Print info for last few epochs
        for (uint256 i = 0; i <= currentEpoch && i < 5; i++) {
            uint256 ep = currentEpoch >= 4 ? currentEpoch - 4 + i : i;
            GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(ep);
            console.log(
                string.concat(
                    "  Epoch ",
                    vm.toString(ep),
                    ": finalized=",
                    info.finalized ? "true" : "false",
                    " executed=",
                    info.executed ? "true" : "false",
                    " winner=",
                    vm.toString(info.winningOption),
                    " budget=",
                    vm.toString(info.budget)
                )
            );
        }

        bytes32 actionHash = keccak256(bytes(action));

        _initTxTracking();

        // ---- Vote (uses voter key) ----
        if (actionHash == keccak256("vote") || actionHash == keccak256("all")) {
            vm.startBroadcast(voterPrivateKey);
            _doVote(voter, voteOption, currentEpoch, voterAddr);
            vm.stopBroadcast();
        }

        // ---- Finalize + Execute (uses keeper key) ----
        if (
            actionHash == keccak256("finalize") || actionHash == keccak256("execute")
                || actionHash == keccak256("all") || actionHash == keccak256("forceExecute")
        ) {
            vm.startBroadcast(keeperPrivateKey);

            if (actionHash == keccak256("finalize") || actionHash == keccak256("all")) {
                _doFinalize(voter, revenueAmount, currentEpoch);
            }

            if (actionHash == keccak256("execute") || actionHash == keccak256("all")) {
                _doExecute(voter, currentEpoch);
            }

            if (actionHash == keccak256("forceExecute")) {
                _doForceExecute(voter);
            }

            vm.stopBroadcast();
        }

        _printTxSummary();
    }

    function _doVote(GovernanceVoter voter, uint8 option, uint256 currentEpoch, address voterAddr) internal {
        string[4] memory optionNames = ["Treasury", "BuyBurnBMX", "BuyBurnLP", "Participation"];

        GovernanceVoter.UserVote memory uv = voter.getUserVote(currentEpoch, voterAddr);
        if (uv.option != 0) {
            console.log("Already voted in epoch", currentEpoch, "with option", uv.option);
            return;
        }

        if (!voter.isOptionEligible(option)) {
            console.log("Option", option, "is ineligible this epoch (3-win cooldown)");
            return;
        }

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(currentEpoch);
        if (info.finalized) {
            console.log("Epoch", currentEpoch, "already finalized, cannot vote");
            return;
        }

        console.log(
            string.concat(
                "Voting for option ",
                vm.toString(option),
                " (",
                optionNames[option - 1],
                ") in epoch ",
                vm.toString(currentEpoch)
            )
        );
        console.log("(Advance voting: this vote directs epoch", currentEpoch + 1, "budget)");

        voter.vote(option);
        _recordTx(string.concat("GovernanceVoter.vote(", vm.toString(option), ")"));
    }

    function _doFinalize(GovernanceVoter voter, uint256 revenueAmount, uint256 currentEpoch) internal {
        uint256 epochToFinalize = type(uint256).max;
        for (uint256 i = 0; i < currentEpoch; i++) {
            GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(i);
            if (!info.finalized) {
                epochToFinalize = i;
                break;
            }
        }

        if (epochToFinalize == type(uint256).max) {
            console.log("No epochs ready to finalize. Current epoch", currentEpoch, "is still active.");
            console.log("Wait for epoch to end, then re-run with ACTION=finalize");
            return;
        }

        // Send revenue to voter before finalizing
        address weth = voter.WETH();
        uint256 existingBalance = IERC20(weth).balanceOf(address(voter));
        if (revenueAmount > 0 && IERC20(weth).balanceOf(msg.sender) >= revenueAmount) {
            IERC20(weth).transfer(address(voter), revenueAmount);
            _recordTx("Transfer WETH revenue to GovernanceVoter");
            console.log("Sent", revenueAmount, "WETH as simulated revenue");
        } else if (existingBalance > 0) {
            console.log("GovernanceVoter already has", existingBalance, "WETH");
        } else {
            console.log("WARNING: No WETH balance and no revenue sent. Budget will be 0.");
        }

        console.log("Finalizing epoch", epochToFinalize);
        voter.finalize(epochToFinalize, type(uint256).max);
        _recordTx(string.concat("GovernanceVoter.finalize(", vm.toString(epochToFinalize), ")"));

        GovernanceVoter.EpochInfo memory result = voter.getEpochInfo(epochToFinalize);
        string[4] memory optionNames = ["Treasury", "BuyBurnBMX", "BuyBurnLP", "Participation"];
        console.log(
            string.concat(
                "  Winner: ",
                vm.toString(result.winningOption),
                " (",
                optionNames[result.winningOption - 1],
                ")",
                " Budget: ",
                vm.toString(result.budget)
            )
        );
    }

    function _doExecute(GovernanceVoter voter, uint256 currentEpoch) internal {
        uint256 epochToExecute = type(uint256).max;
        for (uint256 i = 0; i < currentEpoch; i++) {
            GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(i);
            if (info.finalized && !info.executed) {
                epochToExecute = i;
                break;
            }
        }

        if (epochToExecute == type(uint256).max) {
            console.log("No epochs ready to execute.");
            return;
        }

        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(epochToExecute);
        console.log(
            string.concat(
                "Executing epoch ",
                vm.toString(epochToExecute),
                " winner: ",
                vm.toString(info.winningOption),
                " budget: ",
                vm.toString(info.budget)
            )
        );

        voter.execute(epochToExecute, 0, 0, block.timestamp);
        _recordTx(string.concat("GovernanceVoter.execute(", vm.toString(epochToExecute), ")"));
        console.log("  Executed successfully");
    }

    function _doForceExecute(GovernanceVoter voter) internal {
        uint256 epochToForce = vm.envOr("FORCE_EPOCH", uint256(0));
        GovernanceVoter.EpochInfo memory info = voter.getEpochInfo(epochToForce);

        if (!info.finalized) {
            console.log("Epoch", epochToForce, "not finalized yet");
            return;
        }
        if (info.executed) {
            console.log("Epoch", epochToForce, "already executed");
            return;
        }

        console.log("Force-executing epoch", epochToForce);
        voter.forceMarkExecuted(epochToForce);
        _recordTx(string.concat("GovernanceVoter.forceMarkExecuted(", vm.toString(epochToForce), ")"));
    }
}

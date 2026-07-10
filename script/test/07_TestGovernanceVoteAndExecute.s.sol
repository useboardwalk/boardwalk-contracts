// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseTestScript} from "./BaseTestScript.s.sol";
import {GovernanceVoter} from "src/governance/GovernanceVoter.sol";

/// @title TestGovernanceVoteAndExecute - Exercise the governance lifecycle on a test deployment
/// @notice Supports two wallets: a VOTER (sbf fee-tracker token holder) and a KEEPER (deployer/owner).
///         Runs through: vote → wait epoch → finalize → execute for each option.
///
/// Required env:
///   DEPLOYER_PRIVATE_KEY — keeper/owner key from 06_TestGovernanceDeploy
///   GOVERNANCE_VOTER     — GovernanceVoter contract address
///
/// Optional env:
///   VOTER_PRIVATE_KEY — sbf fee-tracker token holder key for voting (defaults to DEPLOYER_PRIVATE_KEY)
///   VOTE_OPTION       — 1=Treasury, 2=BuyBurnBMX, 3=BuyBurnLP, 4=Participation (default: 1;
///                       option names predate the migration — the buy&burn asset is the deployment's
///                       protocol token, BWS on Arbitrum)
///   REVENUE_AMOUNT    — WETH to deposit via depositRevenue (default: 0.0001 ether)
///   ACTION            — "vote", "deposit", "finalize", "execute", "forceExecute", or "all" (default: "all")
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

        // ---- Deposit / Finalize / Execute (uses keeper key) ----
        if (
            actionHash == keccak256("deposit") || actionHash == keccak256("finalize")
                || actionHash == keccak256("execute") || actionHash == keccak256("all")
                || actionHash == keccak256("forceExecute")
        ) {
            vm.startBroadcast(keeperPrivateKey);

            if (actionHash == keccak256("deposit") || actionHash == keccak256("all")) {
                _doDeposit(voter, revenueAmount);
            }

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

    function _doVote(
        GovernanceVoter voter,
        uint8 option,
        uint256 currentEpoch,
        address voterAddr
    ) internal {
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

    /// @notice Deposit `amount` WETH into the voter via `depositRevenue`. Credits
    ///         `epochRevenue[currentEpoch()]` — operators should call this WHILE the target epoch
    ///         is live, before block.timestamp moves into the next epoch.
    function _doDeposit(
        GovernanceVoter voter,
        uint256 amount
    ) internal {
        if (amount == 0) {
            console.log("REVENUE_AMOUNT is 0, skipping deposit");
            return;
        }

        address weth = voter.WETH();
        address depositor = voter.feeCollector();

        if (msg.sender != depositor) {
            console.log("WARNING: broadcasting key is NOT the feeCollector; cannot call depositRevenue.");
            console.log("  broadcaster:", msg.sender);
            console.log("  expected   :", depositor);
            console.log("  Skipping the deposit. Set DEPLOYER_PRIVATE_KEY to the depositor's key, or");
            console.log("  have the depositor independently call depositRevenue.");
            return;
        }

        if (IERC20(weth).balanceOf(msg.sender) < amount) {
            console.log("WARNING: depositor has insufficient WETH balance for the requested deposit.");
            console.log("  required:", amount);
            console.log("  balance :", IERC20(weth).balanceOf(msg.sender));
            return;
        }

        uint256 epochCredited = voter.currentEpoch();
        uint256 priorEpochRevenue = voter.epochRevenue(epochCredited);

        IERC20(weth).approve(address(voter), amount);
        voter.depositRevenue(amount);
        _recordTx("GovernanceVoter.depositRevenue(...)");

        console.log("Deposited", amount, "WETH via depositRevenue");
        console.log("  Credited to epochRevenue[", epochCredited, "]");
        console.log("  epochRevenue[", epochCredited, "] now:", priorEpochRevenue + amount);
    }

    function _doFinalize(
        GovernanceVoter voter,
        uint256 revenueAmount,
        uint256 currentEpoch
    ) internal {
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

        // depositRevenue credits the CURRENT epoch only. The epoch we are about
        // to finalize (`epochToFinalize`) is necessarily PAST, so any deposit landing here funds
        // a FUTURE epoch — not `epochToFinalize`. Print both numbers loudly so operators don't
        // misread `result.budget` as "the amount I just deposited". `epochToFinalize`'s budget
        // comes from deposits that landed while it was the current epoch.
        if (revenueAmount > 0) {
            uint256 currentEpochAtDeposit = voter.currentEpoch();
            console.log("--- Inline depositRevenue inside _doFinalize ---");
            console.log("  Target finalize epoch:", epochToFinalize);
            console.log("  Current (live) epoch :", currentEpochAtDeposit);
            console.log("  Deposit will fund epochRevenue[", currentEpochAtDeposit, "] -- NOT epoch", epochToFinalize);
            console.log("  To target a specific epoch's budget, run ACTION=deposit during that epoch.");
            _doDeposit(voter, revenueAmount);
        }

        uint256 targetEpochRevenue = voter.epochRevenue(epochToFinalize);
        console.log("epochRevenue[", epochToFinalize, "] before finalize:", targetEpochRevenue);
        if (targetEpochRevenue == 0) {
            console.log("  -> result.budget will be 0 because no deposits landed while this epoch was live.");
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

    function _doExecute(
        GovernanceVoter voter,
        uint256 currentEpoch
    ) internal {
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

    function _doForceExecute(
        GovernanceVoter voter
    ) internal {
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

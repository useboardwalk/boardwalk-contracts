// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IGovernanceVoter {
    struct EpochInfo {
        uint256 snapshotTotalWeight;
        uint256 budget;
        uint256 totalVoteWeight;
        uint256[4] optionWeights;
        uint64 voterCount;
        uint8 winningOption;
        bool snapshotSet;
        bool finalized;
        bool executed;
    }

    struct UserVote {
        uint248 weight;
        uint8 option;
    }

    error EpochNotActive();
    error AlreadyVoted();
    error InvalidOption();
    error OptionIneligible(uint8 option);
    error InsufficientVotingWeight();
    error InsufficientParticipationPoints();
    error EpochNotFinalized();
    error EpochAlreadyFinalized();
    error EpochAlreadyExecuted();
    error EpochNotExecutable();
    error PreviousEpochNotExecuted();
    error GovernanceBurnOutOfRange(uint256 amount);
    error NotKeeper();
    error EpochNotOverdue();
    error FinalizationInProgress();
    error WrongFinalizeEpoch();
    error ZeroBatch();
    error ZeroAddress();
    error PeersAlreadyInitialized();
    error PeerWiringMismatch();
    error PeersNotInitialized();

    event Voted(uint256 indexed epoch, address indexed voter, uint8 option, uint256 weight);
    event EpochFinalized(uint256 indexed epoch, uint8 winningOption, bool quorumMet, uint256 budget);
    event EpochExecuted(
        uint256 indexed epoch, uint8 option, uint256 raiseTokenAmount, bool forced, address destination
    );
    event GovernanceBurnChanged(uint256 oldAmount, uint256 newAmount);
    event TreasuryChanged(address oldAddress, address newAddress);
    event KeeperChanged(address oldKeeper, address newKeeper);
    event FallbackTreasuryChanged(address oldAddress, address newAddress);
    event PeersInitialized(address lpLocker, address participationDistributor);

    function initializePeers(
        address _lpLocker,
        address _participationDistributor
    ) external;
    function vote(
        uint8 option
    ) external;
    function finalize(
        uint256 epoch,
        uint256 maxBatch
    ) external;
    function execute(
        uint256 epoch,
        uint256 amountOutMin,
        uint256 liquidity
    ) external;
    function forceMarkExecuted(
        uint256 epoch
    ) external;
    function currentEpoch() external view returns (uint256);
    function finalizationInProgress() external view returns (bool);
    function treasury() external view returns (address);
    function accountedBudget() external view returns (uint256);
    function getEpochInfo(
        uint256 epoch
    ) external view returns (EpochInfo memory);
    function getUserVote(
        uint256 epoch,
        address user
    ) external view returns (UserVote memory);
    function isOptionEligible(
        uint8 option
    ) external view returns (bool);
    function getEpochVoters(
        uint256 epoch
    ) external view returns (address[] memory);
}

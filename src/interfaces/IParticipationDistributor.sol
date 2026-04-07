// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IParticipationDistributor {
    struct StreamInfo {
        uint256 totalBmx;
        uint256 totalWeight;
        uint256 startTime;
    }

    error NotGovernanceVoter();
    error StreamAlreadyExists();
    error NothingToClaim();

    event StreamCreated(uint256 indexed epoch, uint256 totalBmx, uint256 totalWeight);
    event Claimed(uint256 indexed epoch, address indexed user, uint256 amount);

    function GOVERNANCE_VOTER() external view returns (address);

    function createStream(
        uint256 epoch,
        uint256 bmxAmount
    ) external;
    function claim(
        uint256 epoch
    ) external;
    function claimable(
        uint256 epoch,
        address user
    ) external view returns (uint256);
}

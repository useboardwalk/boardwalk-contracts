// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4PositionManager} from "../interfaces/IV4PositionManager.sol";
import {IGovernanceVoter} from "../interfaces/IGovernanceVoter.sol";

/// @title LPLocker - Permanent lock for Uniswap v4 LP position NFTs
/// @notice Holds LP position NFTs permanently. Can harvest accrued trading fees to treasury.
contract LPLocker {
    // ============ Immutables ============

    address public immutable POSITION_MANAGER;
    address public immutable GOVERNANCE_VOTER;
    address public immutable CURRENCY0;
    address public immutable CURRENCY1;

    // ============ State ============

    mapping(uint256 => bool) public lockedPositions;
    uint256[] public lockedTokenIds;

    // ============ Errors ============

    error NotAuthorized();
    error OnlyPositionManager();
    error PositionNotLocked();
    error AlreadyLocked();
    error NoPositions();

    // ============ Events ============

    event LPLocked(uint256 indexed tokenId);
    event FeesClaimed(uint256 indexed tokenId);

    // ============ Constructor ============

    constructor(
        address _positionManager,
        address _governanceVoter,
        address _currency0,
        address _currency1
    ) {
        POSITION_MANAGER = _positionManager;
        GOVERNANCE_VOTER = _governanceVoter;
        CURRENCY0 = _currency0;
        CURRENCY1 = _currency1;
    }

    /// @dev Accept native ETH from PositionManager during fee claiming
    receive() external payable {
        if (msg.sender != POSITION_MANAGER) revert OnlyPositionManager();
    }

    // ============ Position Registration ============

    /// @notice Register a minted v4 LP position as permanently locked.
    ///         Called by GovernanceVoter after minting a position with LP_LOCKER as recipient.
    /// @param tokenId The v4 position NFT token ID
    function lockPosition(
        uint256 tokenId
    ) external {
        if (msg.sender != GOVERNANCE_VOTER) revert NotAuthorized();
        _registerLock(tokenId);
    }

    // ============ ERC721 Receiver ============

    /// @notice Accept incoming position NFTs and mark them as locked.
    /// @dev Only the configured v4 position manager is allowed to trigger auto-locking.
    function onERC721Received(
        address,
        address,
        uint256 tokenId,
        bytes calldata
    ) external returns (bytes4) {
        if (msg.sender != POSITION_MANAGER) revert NotAuthorized();
        _registerLock(tokenId);
        return this.onERC721Received.selector;
    }

    // ============ Fee Collection ============

    /// @notice Harvest accrued trading fees from a locked v4 LP position and send to treasury.
    /// @param tokenId The v4 position NFT token ID
    /// @param deadline Transaction deadline timestamp
    function claimFees(
        uint256 tokenId,
        uint256 deadline
    ) external {
        if (!lockedPositions[tokenId]) revert PositionNotLocked();
        _claimFees(tokenId, deadline);
    }

    /// @notice Harvest accrued trading fees from all locked positions in a single transaction.
    /// @param deadline Transaction deadline timestamp
    function claimAllFees(
        uint256 deadline
    ) external {
        uint256 len = lockedTokenIds.length;
        if (len == 0) revert NoPositions();

        for (uint256 i; i < len; ++i) {
            _claimFees(lockedTokenIds[i], deadline);
        }
    }

    // ============ View Functions ============

    /// @notice Get all locked position token IDs
    function getLockedPositions() external view returns (uint256[] memory) {
        return lockedTokenIds;
    }

    // ============ Internal ============

    function _registerLock(
        uint256 tokenId
    ) internal {
        if (lockedPositions[tokenId]) revert AlreadyLocked();
        lockedPositions[tokenId] = true;
        lockedTokenIds.push(tokenId);
        emit LPLocked(tokenId);
    }

    function _claimFees(
        uint256 tokenId,
        uint256 deadline
    ) internal {
        address currentTreasury = IGovernanceVoter(GOVERNANCE_VOTER).treasury();

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), "");
        params[1] = abi.encode(CURRENCY0, CURRENCY1, currentTreasury);

        IV4PositionManager(POSITION_MANAGER).modifyLiquidities(abi.encode(actions, params), deadline);

        emit FeesClaimed(tokenId);
    }
}

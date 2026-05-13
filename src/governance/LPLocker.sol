// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4PositionManager} from "../interfaces/IV4PositionManager.sol";
import {IGovernanceVoter} from "../interfaces/IGovernanceVoter.sol";

/// @title LPLocker
/// @notice Permanent vault for Uniswap v4 LP position NFTs minted by governance Option 3. Locked
///         positions can never be unlocked; only their accrued trading fees can be harvested.
contract LPLocker {
    address public immutable POSITION_MANAGER;
    address public immutable GOVERNANCE_VOTER;
    address public immutable CURRENCY0;
    address public immutable CURRENCY1;

    mapping(uint256 => bool) public lockedPositions;
    uint256[] public lockedTokenIds;

    error NotAuthorized();
    error OnlyPositionManager();
    error PositionNotLocked();
    error AlreadyLocked();
    error NoPositions();

    event LPLocked(uint256 indexed tokenId);
    event FeesClaimed(uint256 indexed tokenId);

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

    /// @dev Accepts native ETH from PositionManager during `claimFees`.
    receive() external payable {
        if (msg.sender != POSITION_MANAGER) revert OnlyPositionManager();
    }

    /// @notice Called by GovernanceVoter after minting a v4 position with this contract as recipient.
    function lockPosition(
        uint256 tokenId
    ) external {
        if (msg.sender != GOVERNANCE_VOTER) revert NotAuthorized();
        _registerLock(tokenId);
    }

    /// @notice Harvest accrued v4 trading fees for a single locked position to the current treasury.
    function claimFees(
        uint256 tokenId,
        uint256 deadline
    ) external {
        if (!lockedPositions[tokenId]) revert PositionNotLocked();
        _claimFees(tokenId, deadline);
    }

    function claimAllFees(
        uint256 deadline
    ) external {
        uint256 len = lockedTokenIds.length;
        if (len == 0) revert NoPositions();

        for (uint256 i; i < len; ++i) {
            _claimFees(lockedTokenIds[i], deadline);
        }
    }

    function getLockedPositions() external view returns (uint256[] memory) {
        return lockedTokenIds;
    }

    function _registerLock(
        uint256 tokenId
    ) internal {
        if (lockedPositions[tokenId]) revert AlreadyLocked();
        lockedPositions[tokenId] = true;
        lockedTokenIds.push(tokenId);
        emit LPLocked(tokenId);
    }

    /// @dev `DECREASE_LIQUIDITY(0) + TAKE_PAIR` harvests accrued fees without removing principal.
    ///      Treasury is read live from GovernanceVoter so it tracks setter changes automatically.
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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

/// @title Timelocked - Base contract for inline signal/execute timelock pattern
/// @notice Supports per-action delay (7-day default, 21-day for governance) with 7-day expiry window
abstract contract Timelocked {
    // ============ Constants ============

    uint256 public constant TIMELOCK_DELAY = 7 days;
    uint256 public constant TIMELOCK_EXPIRY = 7 days;

    // ============ Types ============

    struct PendingChange {
        bytes32 dataHash;
        uint256 signalTime;
        uint256 delay;
    }

    // ============ State ============

    mapping(bytes32 => PendingChange) public pendingChanges;
    mapping(bytes32 => PendingChange) public pendingBurns;
    mapping(bytes32 => bool) public burnedActions;

    // ============ Errors ============

    error TimelockDataMismatch();
    error TimelockTooEarly(uint256 executeTime);
    error TimelockExpired(uint256 expiredAt);
    error TimelockNotSignaled();
    error ActionIsBurned(bytes32 action);
    error ActionAlreadyBurned();

    // ============ Events ============

    event ChangeSignaled(bytes32 indexed action, bytes32 dataHash, uint256 executeTime, uint256 expiresAt);
    event ChangeExecuted(bytes32 indexed action);
    event ChangeCanceled(bytes32 indexed action);
    event ActionBurnSignaled(bytes32 indexed action, uint256 executeTime, uint256 expiresAt);
    event ActionBurnExecuted(bytes32 indexed action);
    event ActionBurnCanceled(bytes32 indexed action);

    // ============ Internal Functions ============

    /// @dev Signal a pending change with the default 7-day delay.
    function _signal(
        bytes32 action,
        bytes32 dataHash
    ) internal {
        _signal(action, dataHash, TIMELOCK_DELAY);
    }

    /// @dev Signal a pending change with a custom delay. Overwrites any existing pending change.
    /// @param action Unique identifier for the change (e.g., keccak256("SET_TREASURY"))
    /// @param dataHash keccak256 of the new value(s) to be set on execution
    /// @param delay Timelock delay in seconds (committed at signal time)
    function _signal(
        bytes32 action,
        bytes32 dataHash,
        uint256 delay
    ) internal {
        if (burnedActions[action]) revert ActionIsBurned(action);
        pendingChanges[action] = PendingChange({dataHash: dataHash, signalTime: block.timestamp, delay: delay});
        emit ChangeSignaled(action, dataHash, block.timestamp + delay, block.timestamp + delay + TIMELOCK_EXPIRY);
    }

    /// @dev Execute a pending change. Reads delay from storage (committed at signal time).
    /// @param action Unique identifier matching the signal call
    /// @param dataHash Must match the dataHash from the signal call
    function _execute(
        bytes32 action,
        bytes32 dataHash
    ) internal {
        if (burnedActions[action]) revert ActionIsBurned(action);
        _validateWindow(pendingChanges[action], dataHash);
        delete pendingChanges[action];
        emit ChangeExecuted(action);
    }

    /// @dev Cancel a pending change.
    /// @param action Unique identifier matching the signal call
    function _cancel(
        bytes32 action
    ) internal {
        delete pendingChanges[action];
        emit ChangeCanceled(action);
    }

    // ============ Burn Functions ============

    /// @dev Signal a permanent burn of a timelocked action with a custom delay.
    ///      Uses dedicated pendingBurns storage (isolated from pendingChanges).
    function _signalBurn(
        bytes32 action,
        uint256 delay
    ) internal {
        if (burnedActions[action]) revert ActionAlreadyBurned();
        pendingBurns[action] =
            PendingChange({dataHash: keccak256(abi.encode(action)), signalTime: block.timestamp, delay: delay});
        emit ActionBurnSignaled(action, block.timestamp + delay, block.timestamp + delay + TIMELOCK_EXPIRY);
    }

    /// @dev Execute a previously signaled burn. Irreversible. Also clears any pending change for the action.
    function _executeBurn(
        bytes32 action
    ) internal {
        if (burnedActions[action]) revert ActionAlreadyBurned();
        _validateWindow(pendingBurns[action], keccak256(abi.encode(action)));
        delete pendingBurns[action];
        burnedActions[action] = true;

        if (pendingChanges[action].signalTime > 0) {
            delete pendingChanges[action];
        }

        emit ActionBurnExecuted(action);
    }

    /// @dev Cancel a previously signaled burn.
    function _cancelBurn(
        bytes32 action
    ) internal {
        delete pendingBurns[action];
        emit ActionBurnCanceled(action);
    }

    // ============ Public Admin Functions ============

    /// @notice Signal a pending change for any timelocked action. Auth via _authAdmin hook.
    function signalAction(
        bytes32 action,
        bytes32 dataHash
    ) external {
        _authAdmin(action);
        _signal(action, dataHash, _actionDelay(action));
    }

    /// @notice Cancel a pending change for any timelocked action. Auth via _authAdmin hook.
    function cancelAction(
        bytes32 action
    ) external {
        _authAdmin(action);
        _cancel(action);
    }

    /// @notice Signal permanent burn of a timelocked action. Auth via _authAdmin hook.
    function signalBurnAction(
        bytes32 action
    ) external {
        _authAdmin(action);
        _signalBurn(action, _burnDelay(action));
    }

    /// @notice Execute a previously signaled action burn. Permissionless after delay.
    function executeBurnAction(
        bytes32 action
    ) external {
        _executeBurn(action);
    }

    /// @notice Cancel a previously signaled action burn. Auth via _authAdmin hook.
    function cancelBurnAction(
        bytes32 action
    ) external {
        _authAdmin(action);
        _cancelBurn(action);
    }

    // ============ Internal Helpers ============

    /// @dev Shared window validation for both _execute and _executeBurn
    function _validateWindow(
        PendingChange memory pending,
        bytes32 expectedHash
    ) internal view {
        if (pending.signalTime == 0) revert TimelockNotSignaled();
        if (pending.dataHash != expectedHash) revert TimelockDataMismatch();
        uint256 executeTime = pending.signalTime + pending.delay;
        if (block.timestamp < executeTime) revert TimelockTooEarly(executeTime);
        if (block.timestamp > executeTime + TIMELOCK_EXPIRY) revert TimelockExpired(executeTime + TIMELOCK_EXPIRY);
    }

    /// @dev Shared view helper for pending change/burn info
    function _pendingInfo(
        PendingChange memory pending
    ) internal pure returns (bool isPending, uint256 executeTime, uint256 expiresAt) {
        isPending = pending.signalTime > 0;
        if (isPending) {
            executeTime = pending.signalTime + pending.delay;
            expiresAt = executeTime + TIMELOCK_EXPIRY;
        }
    }

    // ============ Hooks (override in derived contracts) ============

    /// @dev Authorization gate for signal, cancel, and burn operations. Must be overridden.
    function _authAdmin(
        bytes32 action
    ) internal virtual;

    /// @dev Delay for action signals. Default 7 days. Override for custom delays.
    function _actionDelay(
        bytes32
    ) internal view virtual returns (uint256) {
        return TIMELOCK_DELAY;
    }

    /// @dev Delay for burn signals. Defaults to the action's own delay.
    function _burnDelay(
        bytes32 action
    ) internal view virtual returns (uint256) {
        return _actionDelay(action);
    }

    // ============ View Functions ============

    /// @notice Check if an action has been permanently burned
    function isActionBurned(
        bytes32 action
    ) external view returns (bool) {
        return burnedActions[action];
    }

    /// @notice Check if a change is pending and when it can be executed
    function getPendingChange(
        bytes32 action
    ) external view returns (bool isPending, uint256 executeTime, uint256 expiresAt) {
        return _pendingInfo(pendingChanges[action]);
    }

    /// @notice Check if a burn is pending and when it can be executed
    function getPendingBurn(
        bytes32 action
    ) external view returns (bool isPending, uint256 executeTime, uint256 expiresAt) {
        return _pendingInfo(pendingBurns[action]);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

/// @title Timelocked
/// @notice Generic signal/execute/burn pattern with per-action delays. Default 7-day delay and
///         7-day expiry window. Inheritors implement `_authAdmin` and may override `_actionDelay`.
abstract contract Timelocked {
    uint256 public constant TIMELOCK_DELAY = 7 days;
    uint256 public constant TIMELOCK_EXPIRY = 7 days;

    struct PendingChange {
        bytes32 dataHash;
        uint256 signalTime;
        uint256 delay;
    }

    mapping(bytes32 => PendingChange) public pendingChanges;
    mapping(bytes32 => PendingChange) public pendingBurns;
    mapping(bytes32 => bool) public burnedActions;

    error TimelockDataMismatch();
    error TimelockTooEarly(uint256 executeTime);
    error TimelockExpired(uint256 expiredAt);
    error TimelockNotSignaled();
    error ActionIsBurned(bytes32 action);
    error ActionAlreadyBurned();

    event ChangeSignaled(bytes32 indexed action, bytes32 dataHash, uint256 executeTime, uint256 expiresAt);
    event ChangeExecuted(bytes32 indexed action);
    event ChangeCanceled(bytes32 indexed action);
    event ActionBurnSignaled(bytes32 indexed action, uint256 executeTime, uint256 expiresAt);
    event ActionBurnExecuted(bytes32 indexed action);
    event ActionBurnCanceled(bytes32 indexed action);

    function _signal(
        bytes32 action,
        bytes32 dataHash
    ) internal {
        _signal(action, dataHash, TIMELOCK_DELAY);
    }

    /// @dev `delay` is committed at signal time and read back on execute. Overwrites any pending change.
    function _signal(
        bytes32 action,
        bytes32 dataHash,
        uint256 delay
    ) internal {
        if (burnedActions[action]) revert ActionIsBurned(action);
        pendingChanges[action] = PendingChange({dataHash: dataHash, signalTime: block.timestamp, delay: delay});
        emit ChangeSignaled(action, dataHash, block.timestamp + delay, block.timestamp + delay + TIMELOCK_EXPIRY);
    }

    function _execute(
        bytes32 action,
        bytes32 dataHash
    ) internal {
        if (burnedActions[action]) revert ActionIsBurned(action);
        _validateWindow(pendingChanges[action], dataHash);
        delete pendingChanges[action];
        emit ChangeExecuted(action);
    }

    function _cancel(
        bytes32 action
    ) internal {
        delete pendingChanges[action];
        emit ChangeCanceled(action);
    }

    /// @dev Burn storage is isolated from pendingChanges so a pending change can coexist with a
    ///      pending burn until the burn lands.
    function _signalBurn(
        bytes32 action,
        uint256 delay
    ) internal {
        if (burnedActions[action]) revert ActionAlreadyBurned();
        pendingBurns[action] =
            PendingChange({dataHash: keccak256(abi.encode(action)), signalTime: block.timestamp, delay: delay});
        emit ActionBurnSignaled(action, block.timestamp + delay, block.timestamp + delay + TIMELOCK_EXPIRY);
    }

    /// @dev Irreversible. Clears any in-flight change for the action so it cannot land post-burn.
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

    function _cancelBurn(
        bytes32 action
    ) internal {
        delete pendingBurns[action];
        emit ActionBurnCanceled(action);
    }

    function signalAction(
        bytes32 action,
        bytes32 dataHash
    ) external {
        _authAdmin(action);
        _signal(action, dataHash, _actionDelay(action));
    }

    function cancelAction(
        bytes32 action
    ) external {
        _authAdmin(action);
        _cancel(action);
    }

    function signalBurnAction(
        bytes32 action
    ) external {
        _authAdmin(action);
        _signalBurn(action, _burnDelay(action));
    }

    /// @notice Permissionless after the burn delay; the auth gate is at signal time.
    function executeBurnAction(
        bytes32 action
    ) external {
        _executeBurn(action);
    }

    function cancelBurnAction(
        bytes32 action
    ) external {
        _authAdmin(action);
        _cancelBurn(action);
    }

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

    function _pendingInfo(
        PendingChange memory pending
    ) internal pure returns (bool isPending, uint256 executeTime, uint256 expiresAt) {
        isPending = pending.signalTime > 0;
        if (isPending) {
            executeTime = pending.signalTime + pending.delay;
            expiresAt = executeTime + TIMELOCK_EXPIRY;
        }
    }

    /// @dev Authorization gate for signal/cancel/burn. Inheritors implement (e.g. `onlyOwner`).
    function _authAdmin(
        bytes32 action
    ) internal virtual;

    function _actionDelay(
        bytes32
    ) internal view virtual returns (uint256) {
        return TIMELOCK_DELAY;
    }

    function _burnDelay(
        bytes32 action
    ) internal view virtual returns (uint256) {
        return _actionDelay(action);
    }

    function isActionBurned(
        bytes32 action
    ) external view returns (bool) {
        return burnedActions[action];
    }

    function getPendingChange(
        bytes32 action
    ) external view returns (bool isPending, uint256 executeTime, uint256 expiresAt) {
        return _pendingInfo(pendingChanges[action]);
    }

    function getPendingBurn(
        bytes32 action
    ) external view returns (bool isPending, uint256 executeTime, uint256 expiresAt) {
        return _pendingInfo(pendingBurns[action]);
    }
}

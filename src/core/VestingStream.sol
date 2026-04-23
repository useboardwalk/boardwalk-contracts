// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Timelocked} from "../base/Timelocked.sol";

/// @title VestingStream
/// @notice Per-launch clone (Advanced path only). Up to 5 recipients vest linearly over 3 years
///         after a 7-day cliff. Amounts and schedule are immutable; only recipient addresses can
///         change, and only the issuer can signal a change via the 7-day timelock.
contract VestingStream is Timelocked, Initializable {
    using SafeERC20 for IERC20;

    uint256 public constant CLIFF_DURATION = 7 days;
    uint256 public constant VESTING_DURATION = 3 * 365 days;

    bytes32 public constant ACTION_CHANGE_RECIPIENT = keccak256("CHANGE_RECIPIENT");

    struct VestingAllocation {
        address recipient;
        uint256 totalAmount;
        uint256 claimed;
    }

    IERC20 public token;

    mapping(uint256 => VestingAllocation) public allocations;

    uint256 public allocationCount;
    uint256 public cliffEnd;
    uint256 public vestingEnd;

    address public initAuthorizer;
    address public issuer;

    error NotRecipient();
    error NothingToClaim();
    error CliffNotEnded(uint256 cliffEnd_, uint256 currentTime);
    error ZeroAddress();
    error ArrayLengthMismatch();
    error InvalidAllocationId(uint256 id);
    error NotInitializer();
    error InitializerAlreadySet();
    error NotIssuer();

    event Claimed(uint256 indexed allocationId, address indexed recipient, uint256 amount);
    event VestingInitialized(uint256 cliffEnd_, uint256 vestingEnd_, uint256 allocationCount_);
    event RecipientAddressChanged(uint256 indexed allocationId, address oldAddress, address newAddress);

    constructor() {
        _disableInitializers();
    }

    /// @notice Two-step initializer lock. Called once by the factory; sets the issuer at the same time.
    function setInitializer(
        address _initAuthorizer,
        address _issuer
    ) external {
        if (initAuthorizer != address(0)) revert InitializerAlreadySet();
        if (_initAuthorizer == address(0)) revert ZeroAddress();
        if (_issuer == address(0)) revert ZeroAddress();
        initAuthorizer = _initAuthorizer;
        issuer = _issuer;
    }

    function initialize(
        address _token,
        uint256 _liquiditySeedTime,
        address[] calldata _recipients,
        uint256[] calldata _amounts
    ) external initializer {
        if (msg.sender != initAuthorizer) revert NotInitializer();

        if (_token == address(0)) revert ZeroAddress();
        if (_recipients.length != _amounts.length) revert ArrayLengthMismatch();

        token = IERC20(_token);
        cliffEnd = _liquiditySeedTime + CLIFF_DURATION;
        vestingEnd = cliffEnd + VESTING_DURATION;

        for (uint256 i = 0; i < _recipients.length;) {
            if (_recipients[i] == address(0)) revert ZeroAddress();
            allocations[i] = VestingAllocation({recipient: _recipients[i], totalAmount: _amounts[i], claimed: 0});
            unchecked {
                ++i;
            }
        }
        allocationCount = _recipients.length;

        emit VestingInitialized(cliffEnd, vestingEnd, _recipients.length);
    }

    /// @notice Claim vested tokens for an allocation. Only the current recipient can claim.
    function claim(
        uint256 allocationId
    ) external {
        if (allocationId >= allocationCount) revert InvalidAllocationId(allocationId);

        VestingAllocation storage alloc = allocations[allocationId];
        if (msg.sender != alloc.recipient) revert NotRecipient();

        uint256 amount = claimable(allocationId);
        if (amount == 0) {
            if (block.timestamp < cliffEnd) {
                revert CliffNotEnded(cliffEnd, block.timestamp);
            }
            revert NothingToClaim();
        }

        alloc.claimed += amount;
        token.safeTransfer(alloc.recipient, amount);

        emit Claimed(allocationId, alloc.recipient, amount);
    }

    /// @notice Execute a pending recipient address change. Auto-claims any vested-but-unclaimed
    ///         tokens for the outgoing recipient before switching.
    function executeChangeRecipientAddress(
        uint256 allocationId,
        address newAddress
    ) external {
        if (allocationId >= allocationCount) revert InvalidAllocationId(allocationId);
        bytes32 action = keccak256(abi.encode(ACTION_CHANGE_RECIPIENT, allocationId));
        _execute(action, keccak256(abi.encode(newAddress)));
        if (newAddress == address(0)) revert ZeroAddress();

        VestingAllocation storage alloc = allocations[allocationId];

        uint256 pending = claimable(allocationId);
        if (pending > 0) {
            alloc.claimed += pending;
            token.safeTransfer(alloc.recipient, pending);
            emit Claimed(allocationId, alloc.recipient, pending);
        }

        emit RecipientAddressChanged(allocationId, alloc.recipient, newAddress);
        alloc.recipient = newAddress;
    }

    function _authAdmin(
        bytes32
    ) internal view override {
        if (msg.sender != issuer) revert NotIssuer();
    }

    function claimable(
        uint256 allocationId
    ) public view returns (uint256) {
        if (allocationId >= allocationCount) return 0;
        VestingAllocation memory alloc = allocations[allocationId];
        return _vestedAmount(alloc) - alloc.claimed;
    }

    function totalVested(
        uint256 allocationId
    ) external view returns (uint256) {
        if (allocationId >= allocationCount) return 0;
        return _vestedAmount(allocations[allocationId]);
    }

    function _vestedAmount(
        VestingAllocation memory alloc
    ) private view returns (uint256) {
        if (block.timestamp < cliffEnd) return 0;
        uint256 elapsed = block.timestamp - cliffEnd;
        if (elapsed > VESTING_DURATION) elapsed = VESTING_DURATION;
        return alloc.totalAmount * elapsed / VESTING_DURATION;
    }
}

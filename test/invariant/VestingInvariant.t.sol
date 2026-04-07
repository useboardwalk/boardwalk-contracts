// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VestingStream} from "src/core/VestingStream.sol";

/// @dev Mock ERC20 with mint
contract MockERC20 is ERC20 {
    constructor(
        string memory name,
        string memory symbol
    ) ERC20(name, symbol) {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @title VestingHandler
/// @notice Handler for VestingStream invariant testing
contract VestingHandler is Test {
    VestingStream public vesting;
    MockERC20 public token;
    address[] public recipients;

    uint256 public ghost_totalClaimed;
    mapping(uint256 => uint256) public ghost_allocationClaimed;

    constructor(
        VestingStream _vesting,
        MockERC20 _token,
        address[] memory _recipients
    ) {
        vesting = _vesting;
        token = _token;
        for (uint256 i = 0; i < _recipients.length; i++) {
            recipients.push(_recipients[i]);
        }
    }

    function claim(
        uint256 allocationSeed
    ) external {
        uint256 allocId = bound(allocationSeed, 0, recipients.length - 1);
        address recipient = recipients[allocId];

        uint256 claimable = vesting.claimable(allocId);
        if (claimable == 0) return;

        uint256 balBefore = token.balanceOf(recipient);
        vm.prank(recipient);
        vesting.claim(allocId);
        uint256 claimed = token.balanceOf(recipient) - balBefore;

        ghost_totalClaimed += claimed;
        ghost_allocationClaimed[allocId] += claimed;
    }

    function warpTime(
        uint256 seconds_
    ) external {
        seconds_ = bound(seconds_, 1 hours, 90 days);
        vm.warp(block.timestamp + seconds_);
    }
}

/// @title VestingInvariantTest
/// @notice Invariant tests: claimed <= vested <= totalAmount for all allocations
contract VestingInvariantTest is Test {
    VestingStream internal template;
    VestingStream internal vesting;
    MockERC20 internal token;
    VestingHandler internal handler;

    address internal recipient1;
    address internal recipient2;
    address internal presaleManager;

    uint256 internal constant AMOUNT1 = 700_000e18;
    uint256 internal constant AMOUNT2 = 300_000e18;

    function setUp() public {
        recipient1 = makeAddr("recipient1");
        recipient2 = makeAddr("recipient2");
        presaleManager = makeAddr("presaleManager");

        token = new MockERC20("Token", "TKN");
        template = new VestingStream();

        address clone = Clones.clone(address(template));
        vesting = VestingStream(clone);

        // Set initializer and issuer, then initialize
        vesting.setInitializer(presaleManager, makeAddr("issuer"));

        address[] memory recipients = new address[](2);
        recipients[0] = recipient1;
        recipients[1] = recipient2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = AMOUNT1;
        amounts[1] = AMOUNT2;
        vm.prank(presaleManager);
        vesting.initialize(address(token), block.timestamp, recipients, amounts);

        // Fund vesting contract
        token.mint(address(vesting), AMOUNT1 + AMOUNT2);

        // Warp past cliff (7 days)
        vm.warp(block.timestamp + 7 days + 1);

        handler = new VestingHandler(vesting, token, recipients);
        targetContract(address(handler));
    }

    /// @notice Invariant: total claimed across all allocations <= total allocation
    function invariant_totalClaimedLeTotalAllocation() external view {
        assertLe(handler.ghost_totalClaimed(), AMOUNT1 + AMOUNT2, "Total claimed exceeds total allocation");
    }

    /// @notice Invariant: per-allocation claimed <= allocation amount
    function invariant_perAllocationClaimedLeAmount() external view {
        assertLe(handler.ghost_allocationClaimed(0), AMOUNT1, "Allocation 0 overclaimed");
        assertLe(handler.ghost_allocationClaimed(1), AMOUNT2, "Allocation 1 overclaimed");
    }

    /// @notice Invariant: vesting contract balance >= total unclaimed
    function invariant_vestingBalanceCoversUnclaimed() external view {
        uint256 totalAllocation = AMOUNT1 + AMOUNT2;
        uint256 totalClaimed = handler.ghost_totalClaimed();
        uint256 unclaimed = totalAllocation - totalClaimed;
        uint256 balance = token.balanceOf(address(vesting));
        assertGe(balance, unclaimed, "Vesting balance insufficient for unclaimed");
    }

    /// @notice Invariant: per-allocation (claimed + claimable) never exceeds allocation amount
    ///         This verifies the vesting formula doesn't over-vest
    function invariant_vestedNeverExceedsAllocation() external view {
        uint256[2] memory amounts = [AMOUNT1, AMOUNT2];
        for (uint256 i = 0; i < 2; i++) {
            uint256 claimed = handler.ghost_allocationClaimed(i);
            uint256 claimable = vesting.claimable(i);
            // total vested so far = claimed + claimable
            assertLe(claimed + claimable, amounts[i], "Total vested should never exceed allocation");
        }
    }

    /// @notice Invariant: ghost per-allocation sums to ghost total
    function invariant_ghostConsistency() external view {
        uint256 sum = handler.ghost_allocationClaimed(0) + handler.ghost_allocationClaimed(1);
        assertEq(sum, handler.ghost_totalClaimed(), "Per-allocation ghosts should sum to total ghost");
    }
}

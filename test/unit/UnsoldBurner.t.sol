// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {UnsoldBurner} from "src/token/UnsoldBurner.sol";
import {BWLK} from "src/token/BWLK.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20, MockCcaAuction, RevertingCcaAuction, ReentrantCcaAuction} from "test/bwlk/UnsoldBurnerMocks.sol";

/// @notice Unit tests for `UnsoldBurner`, the permissionless BWLK -> DEAD sink used as the CCA auction's
///         `tokensRecipient`. Covers burn, sweep against a mock CCA, the only-DEAD invariant, and the
///         absence of a rescue path.
contract UnsoldBurnerTest is Test {
    UnsoldBurner internal burner;
    MockERC20 internal bwlk;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");
    address internal thirdParty = makeAddr("thirdParty");

    event Burned(address indexed caller, uint256 amount);
    event TokensSwept(address indexed tokensRecipient, uint256 tokensAmount);

    function setUp() public {
        bwlk = new MockERC20("Boardwalk", "BWLK");
        burner = new UnsoldBurner(address(bwlk));
    }

    // --- constructor -------------------------------------------------------------------------------

    function test_Constructor_SetsImmutables() public view {
        assertEq(address(burner.BWLK()), address(bwlk), "BWLK immutable");
        assertEq(burner.DEAD(), DEAD, "DEAD constant");
    }

    function test_RevertWhen_ConstructorZeroBwlk() public {
        vm.expectRevert(UnsoldBurner.ZeroAddress.selector);
        new UnsoldBurner(address(0));
    }

    // --- burn() ------------------------------------------------------------------------------------

    function test_Burn_SendsFullBalanceToDead_AndEmits() public {
        uint256 amount = 219_466e18;
        bwlk.mint(address(burner), amount);

        vm.expectEmit(true, true, true, true, address(burner));
        emit Burned(address(this), amount);
        burner.burn();

        assertEq(bwlk.balanceOf(DEAD), amount, "DEAD received all");
        assertEq(bwlk.balanceOf(address(burner)), 0, "burner emptied");
    }

    function test_Burn_Permissionless_AnyCaller() public {
        uint256 amount = 1_000e18;
        bwlk.mint(address(burner), amount);

        vm.expectEmit(true, true, true, true, address(burner));
        emit Burned(alice, amount);
        vm.prank(alice);
        burner.burn();

        assertEq(bwlk.balanceOf(DEAD), amount, "DEAD received all");
    }

    function test_RevertWhen_BurnZeroBalance() public {
        vm.expectRevert(UnsoldBurner.NothingToBurn.selector);
        burner.burn();
    }

    function test_RevertWhen_BurnAfterAlreadyBurned() public {
        bwlk.mint(address(burner), 5e18);
        burner.burn();
        vm.expectRevert(UnsoldBurner.NothingToBurn.selector);
        burner.burn();
    }

    // --- sweep(auction) ----------------------------------------------------------------------------

    function test_Sweep_PullsUnsoldThenBurns() public {
        uint256 unsold = 219_466e18;
        MockCcaAuction auction = new MockCcaAuction(IERC20(address(bwlk)), address(burner));
        bwlk.mint(address(auction), unsold);

        // Auction pushes unsold to the burner, then the burner forwards it to DEAD.
        vm.expectEmit(true, true, true, true, address(auction));
        emit TokensSwept(address(burner), unsold);
        vm.expectEmit(true, true, true, true, address(burner));
        emit Burned(address(this), unsold);
        burner.sweep(address(auction));

        assertEq(bwlk.balanceOf(DEAD), unsold, "DEAD received unsold");
        assertEq(bwlk.balanceOf(address(auction)), 0, "auction emptied");
        assertEq(bwlk.balanceOf(address(burner)), 0, "burner emptied");
        assertTrue(auction.sweepUnsoldTokensBlock() != 0, "auction marked swept");
    }

    /// @dev Non-graduation returns the full offered supply; modelled by funding the mock with it.
    function test_Sweep_NonGraduation_FullOfferedSupplyToDead() public {
        uint256 offered = 219_466e18;
        MockCcaAuction auction = new MockCcaAuction(IERC20(address(bwlk)), address(burner));
        bwlk.mint(address(auction), offered);

        burner.sweep(address(auction));

        assertEq(bwlk.balanceOf(DEAD), offered, "full offered supply burned");
    }

    function test_Sweep_Permissionless_AnyCaller() public {
        uint256 unsold = 10e18;
        MockCcaAuction auction = new MockCcaAuction(IERC20(address(bwlk)), address(burner));
        bwlk.mint(address(auction), unsold);

        // The Burned event attributes the burn to the arbitrary (non-deployer) caller.
        vm.expectEmit(true, true, true, true, address(burner));
        emit Burned(keeper, unsold);
        vm.prank(keeper);
        burner.sweep(address(auction));

        assertEq(bwlk.balanceOf(DEAD), unsold, "swept + burned by any caller");
    }

    /// @dev Codeless `auction` (EOA) is skipped, but any BWLK already standing on the burner is still burned.
    function test_Sweep_CodelessAuction_BurnsStandingBalance() public {
        uint256 standing = 42e18;
        bwlk.mint(address(burner), standing);

        vm.expectEmit(true, true, true, true, address(burner));
        emit Burned(address(this), standing);
        burner.sweep(makeAddr("notAnAuction"));

        assertEq(bwlk.balanceOf(DEAD), standing, "standing balance burned despite codeless auction");
        assertEq(bwlk.balanceOf(address(burner)), 0, "burner emptied");
    }

    /// @dev A reentrant auction can only trigger the same terminal burn early: all to DEAD once, no double-move.
    function test_Sweep_ReentrantAuction_BurnsOnceToDeadOnly() public {
        uint256 unsold = 219_466e18;
        ReentrantCcaAuction auction = new ReentrantCcaAuction(IERC20(address(bwlk)), address(burner));
        bwlk.mint(address(auction), unsold);

        burner.sweep(address(auction));

        assertTrue(auction.reentered(), "auction reentered mid-sweep");
        assertEq(bwlk.balanceOf(DEAD), unsold, "exactly the unsold amount reached DEAD");
        assertEq(bwlk.balanceOf(address(burner)), 0, "burner emptied, no double-move");
        assertEq(bwlk.balanceOf(address(auction)), 0, "auction emptied");
    }

    /// @dev The burner is NOT the auction's recipient -> `sweepUnsoldTokens()` reverts NotAuthorized;
    ///      the burner swallows it and still burns whatever it already holds.
    function test_Sweep_NotRecipient_SwallowsRevert_BurnsStanding() public {
        MockCcaAuction auction = new MockCcaAuction(IERC20(address(bwlk)), thirdParty);
        uint256 standing = 7e18;
        bwlk.mint(address(burner), standing);

        burner.sweep(address(auction));

        assertEq(bwlk.balanceOf(DEAD), standing, "standing balance burned");
        assertEq(bwlk.balanceOf(address(auction)), 0, "auction untouched (not swept)");
        assertEq(auction.sweepUnsoldTokensBlock(), 0, "auction was not swept");
    }

    /// @dev Auction reverts hard (a contract that always reverts); burner still burns its standing balance.
    function test_Sweep_AuctionReverts_SwallowsRevert_BurnsStanding() public {
        RevertingCcaAuction auction = new RevertingCcaAuction();
        uint256 standing = 3e18;
        bwlk.mint(address(burner), standing);

        burner.sweep(address(auction));

        assertEq(bwlk.balanceOf(DEAD), standing, "standing balance burned despite auction revert");
    }

    /// @dev Passing a non-contract address with no standing balance is a safe no-op (no revert/event).
    function test_Sweep_NonContractAuction_NoBalance_NoOp() public {
        burner.sweep(makeAddr("notAnAuction"));
        assertEq(bwlk.balanceOf(DEAD), 0, "nothing burned");
        assertEq(bwlk.balanceOf(address(burner)), 0, "burner still empty");
    }

    /// @dev Second sweep of an already-swept auction: auction reverts CannotSweepTokens, swallowed; any
    ///      newly-arrived standing balance is still burned.
    function test_Sweep_AlreadySwept_SwallowsRevert_BurnsNewStanding() public {
        uint256 first = 100e18;
        MockCcaAuction auction = new MockCcaAuction(IERC20(address(bwlk)), address(burner));
        bwlk.mint(address(auction), first);
        burner.sweep(address(auction));
        assertEq(bwlk.balanceOf(DEAD), first, "first sweep burned");

        // More BWLK lands on the burner later (e.g. a manual top-up); a repeat sweep still burns it even
        // though the auction now reverts CannotSweepTokens.
        uint256 second = 4e18;
        bwlk.mint(address(burner), second);
        burner.sweep(address(auction));

        assertEq(bwlk.balanceOf(DEAD), first + second, "new standing balance also burned");
    }

    /// @dev Graduated + fully sold: the sweep succeeds with 0 unsold, so nothing burns and it does not revert.
    function test_Sweep_GraduatedFullySold_ZeroUnsold_NoBurn() public {
        MockCcaAuction auction = new MockCcaAuction(IERC20(address(bwlk)), address(burner));
        // auction holds 0 unsold tokens
        vm.expectEmit(true, true, true, true, address(auction));
        emit TokensSwept(address(burner), 0);
        burner.sweep(address(auction));

        assertEq(bwlk.balanceOf(DEAD), 0, "nothing to burn");
        assertTrue(auction.sweepUnsoldTokensBlock() != 0, "auction still marked swept");
    }

    // --- invariants --------------------------------------------------------------------------------

    /// @notice No path moves BWLK anywhere but DEAD: after a full sweep, only DEAD holds the tokens.
    function test_Invariant_OnlyDeadEverReceivesBwlk() public {
        uint256 unsold = 219_466e18;
        MockCcaAuction auction = new MockCcaAuction(IERC20(address(bwlk)), address(burner));
        bwlk.mint(address(auction), unsold);

        vm.prank(keeper);
        burner.sweep(address(auction));

        assertEq(bwlk.balanceOf(DEAD), unsold, "DEAD holds everything");
        assertEq(bwlk.balanceOf(address(burner)), 0, "burner holds nothing");
        assertEq(bwlk.balanceOf(address(auction)), 0, "auction holds nothing");
        assertEq(bwlk.balanceOf(keeper), 0, "caller gained nothing");
        assertEq(bwlk.balanceOf(thirdParty), 0, "no third party gained anything");
    }

    /// @notice There is no rescue path: a foreign ERC20 mistakenly sent in is permanently stuck; neither
    ///         `burn()` nor `sweep()` can move it, and it never reaches DEAD.
    function test_Invariant_ForeignTokenCannotBeMovedOrRescued() public {
        MockERC20 foreign = new MockERC20("Foreign", "FRN");
        uint256 stuck = 500e18;
        foreign.mint(address(burner), stuck);

        // Give the burner some BWLK too, so burn()/sweep() have real work to do.
        bwlk.mint(address(burner), 1e18);
        burner.burn();
        burner.sweep(makeAddr("notAnAuction"));

        assertEq(foreign.balanceOf(address(burner)), stuck, "foreign token untouched");
        assertEq(foreign.balanceOf(DEAD), 0, "foreign token never reaches DEAD");
        assertEq(bwlk.balanceOf(DEAD), 1e18, "only BWLK was burned");
    }

    // --- fuzz --------------------------------------------------------------------------------------

    function testFuzz_Burn_AnyAmount(
        uint256 amount
    ) public {
        amount = bound(amount, 1, 3_150_000e18);
        bwlk.mint(address(burner), amount);
        vm.prank(alice);
        burner.burn();
        assertEq(bwlk.balanceOf(DEAD), amount, "fuzzed amount fully burned");
    }

    function testFuzz_Sweep_AnyUnsoldAmount(
        uint256 amount
    ) public {
        amount = bound(amount, 1, 3_150_000e18);
        MockCcaAuction auction = new MockCcaAuction(IERC20(address(bwlk)), address(burner));
        bwlk.mint(address(auction), amount);
        burner.sweep(address(auction));
        assertEq(bwlk.balanceOf(DEAD), amount, "fuzzed unsold fully swept + burned");
    }

    // --- against the real BWLK token ----------------------------------------------------------------

    /// @dev Same behaviour against the production BWLK token.
    function test_Burn_RealBwlkToken() public {
        BWLK realBwlk = new BWLK(address(this), address(this));
        UnsoldBurner realBurner = new UnsoldBurner(address(realBwlk));
        uint256 amount = 219_466e18;
        realBwlk.transfer(address(realBurner), amount);

        realBurner.burn();

        assertEq(realBwlk.balanceOf(DEAD), amount, "real BWLK burned to DEAD");
        assertEq(realBwlk.balanceOf(address(realBurner)), 0, "real burner emptied");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {LPLocker} from "src/governance/LPLocker.sol";

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @dev Real v4 PositionManager surface this test needs.
interface IPositionManagerFull {
    function nextTokenId() external view returns (uint256);
    function ownerOf(
        uint256 tokenId
    ) external view returns (address);
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;
    function getPoolAndPositionInfo(
        uint256 tokenId
    ) external view returns (PoolKey memory, uint256);
    function getPositionLiquidity(
        uint256 tokenId
    ) external view returns (uint128);
}

/// @dev GovernanceVoter stand-in: LPLocker.claimFees reads `treasury()` live, and registerPosition
///      pins the position's key against the voter's pool params (set from the picked position).
contract MockVoterTreasury {
    address public treasury;
    uint24 public POOL_FEE;
    int24 public POOL_TICK_SPACING;
    address public POOL_HOOKS;
    bool public constant poolHooksSet = true;

    constructor(
        address t,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) {
        treasury = t;
        POOL_FEE = fee;
        POOL_TICK_SPACING = tickSpacing;
        POOL_HOOKS = hooks;
    }
}

/// @title CcaLpLockingForkTest
/// @notice Base mainnet fork test for the CCA LP-locking flow against the real Uniswap v4
///         PositionManager. A CCA/LBP launch mints the pool's LP position directly to the pool owner
///         (set to LPLocker); the registrar then locks it via `registerPosition`, after which fees are
///         claimable. The "LP NFT owned by the locker" outcome is simulated by transferring a live
///         position into the locker (same on-chain effect as a direct `_mint` by the LBP, no
///         `onERC721Received`), then running `registerPosition` + `claimFees`.
///
/// @dev Run with: forge test --match-contract CcaLpLockingForkTest --fork-url https://mainnet.base.org -vvv
contract CcaLpLockingForkTest is Test {
    address constant BASE_POSITION_MANAGER = 0x7C5f5A4bBd8fD63184577525326123B519429bDc;

    IPositionManagerFull pm = IPositionManagerFull(BASE_POSITION_MANAGER);
    LPLocker public locker;
    MockVoterTreasury public voter;

    address public registrar = makeAddr("registrar");
    address public treasury = makeAddr("treasury");

    uint256 internal tokenId;
    address internal posOwner;
    PoolKey internal poolKey;
    /// @dev A live position NOT owned by the locker, for the negative ownership test (its ownerOf
    ///      must succeed - an arbitrary tokenId +/- 1 may be burned and revert NOT_MINTED instead).
    uint256 internal foreignTokenId;

    event LPLocked(uint256 indexed tokenId);
    event FeesClaimed(uint256 indexed tokenId);

    bool internal forked;

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function setUp() public {
        // Run with --fork-url, or self-fork from BASE_RPC_URL; without either the suite skips
        // (CI runs with no RPC configured).
        if (BASE_POSITION_MANAGER.code.length == 0) {
            string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
            if (bytes(rpcUrl).length == 0) return;
            vm.createSelectFork(rpcUrl);
        }
        forked = true;

        // Find a live v4 position: EOA-owned, nonzero liquidity (a zero-liquidity poke reverts
        // CannotUpdateEmptyPosition in claimFees), hookless pool (a hook with remove-liquidity
        // permissions could revert the claim).
        uint256 nextId = pm.nextTokenId();
        require(nextId > 1, "no positions");
        uint256 floor = nextId > 300 ? nextId - 300 : 1;
        for (uint256 id = nextId - 1; id >= floor; id--) {
            try pm.ownerOf(id) returns (address o) {
                if (o == address(0)) continue;
                if (tokenId == 0 && o.code.length == 0) {
                    (PoolKey memory k,) = pm.getPoolAndPositionInfo(id);
                    if (k.hooks == address(0) && pm.getPositionLiquidity(id) > 0) {
                        tokenId = id;
                        posOwner = o;
                        poolKey = k;
                        continue;
                    }
                }
                // Any other live position serves as the foreign (not-locker-owned) id.
                if (tokenId != 0 && id != tokenId && foreignTokenId == 0) {
                    foreignTokenId = id;
                    break;
                }
            } catch {}
            if (id == 1) break;
        }
        require(tokenId != 0, "no suitable EOA-owned position found");
        require(foreignTokenId != 0, "no second live position found");

        voter = new MockVoterTreasury(treasury, poolKey.fee, poolKey.tickSpacing, poolKey.hooks);
        // Locker currencies must match the position's pool so claimFees' TAKE_PAIR resolves.
        locker = new LPLocker(BASE_POSITION_MANAGER, address(voter), poolKey.currency0, poolKey.currency1, registrar);

        // Simulate the CCA/LBP minting the LP to the pool owner (= LPLocker).
        vm.prank(posOwner);
        pm.transferFrom(posOwner, address(locker), tokenId);
        assertEq(pm.ownerOf(tokenId), address(locker), "locker owns position");
    }

    function testFork_RegisterPosition_LocksCcaLp() public onlyFork {
        assertFalse(locker.lockedPositions(tokenId), "not locked before register");

        vm.expectEmit(true, true, true, true);
        emit LPLocked(tokenId);
        vm.prank(registrar);
        locker.registerPosition(tokenId);

        assertTrue(locker.lockedPositions(tokenId), "position locked");
        uint256[] memory ids = locker.getLockedPositions();
        assertEq(ids.length, 1, "one locked position");
        assertEq(ids[0], tokenId, "tracked id");
    }

    function testFork_RegisterPosition_RevertWhen_NotOwnedByLocker() public onlyFork {
        // A live but non-locker-owned id cannot be registered (picked in setUp so ownerOf succeeds).
        vm.prank(registrar);
        vm.expectRevert(LPLocker.NotPositionOwner.selector);
        locker.registerPosition(foreignTokenId);
    }

    function testFork_ClaimFees_OnRegisteredCcaLp() public onlyFork {
        vm.prank(registrar);
        locker.registerPosition(tokenId);

        // Harvest accrued fees against the real PositionManager (DECREASE_LIQUIDITY(0) + TAKE_PAIR).
        vm.expectEmit(true, true, true, true);
        emit FeesClaimed(tokenId);
        locker.claimFees(tokenId, block.timestamp);
    }

    function testFork_Registrar_CanRenounceAfterLocking() public onlyFork {
        vm.prank(registrar);
        locker.registerPosition(tokenId);

        vm.prank(registrar);
        locker.renounceRegistrar();
        assertEq(locker.registrar(), address(0), "registrar renounced");

        // No further registration possible (admin-free).
        vm.prank(registrar);
        vm.expectRevert(LPLocker.NotRegistrar.selector);
        locker.registerPosition(tokenId);
    }
}

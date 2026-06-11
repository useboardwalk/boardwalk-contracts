// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {BoardwalkClubLockbox} from "src/nft/BoardwalkClubLockbox.sol";
import {CCIPConfig} from "script/CCIPConfig.sol";

/// @title BoardwalkClubLockboxForkTest
/// @notice Base mainnet fork tests against the real SeaDrop collection (ERC721A transfers,
///         operator-filter behavior) and the real CCIP router (fee quoting, onramp acceptance
///         of the message shape).
/// @dev    Env-gated: skipped unless BASE_RPC_URL is set.
///         Run with: BASE_RPC_URL=https://mainnet.base.org forge test --match-contract BoardwalkClubLockboxFork -vvv
contract BoardwalkClubLockboxForkTest is Test {
    /// @dev Original Boardwalk Club SeaDrop collection on Base.
    address internal constant BBC_COLLECTION = 0xcc2AAF39960445ab981aA07ccB3947718635F39E;
    uint256 internal constant TOKEN_ID = 1;

    IERC721 internal bbc = IERC721(BBC_COLLECTION);
    BoardwalkClubLockbox internal lockbox;

    address internal owner = makeAddr("owner");
    address internal mirrorStub = makeAddr("mirrorStub");
    address internal holder;
    bool internal forked;

    modifier onlyFork() {
        if (!forked) vm.skip(true);
        _;
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        forked = true;

        vm.createSelectFork(rpcUrl);
        (address router,) = CCIPConfig.resolve(CCIPConfig.CHAIN_BASE);

        lockbox = new BoardwalkClubLockbox(router, owner, BBC_COLLECTION);

        uint64[] memory selectors = new uint64[](1);
        address[] memory peers = new address[](1);
        selectors[0] = CCIPConfig.SELECTOR_ETHEREUM;
        peers[0] = mirrorStub;
        vm.prank(owner);
        lockbox.initializePeers(selectors, peers);

        holder = bbc.ownerOf(TOKEN_ID);
        vm.deal(holder, 1 ether);
    }

    function testFork_QuoteBridge_RealRouterReturnsFee() public onlyFork {
        uint256 fee = lockbox.quoteBridge(CCIPConfig.SELECTOR_ETHEREUM, TOKEN_ID, holder);
        assertGt(fee, 0, "real router quotes a non-zero native fee for the message shape");
    }

    function testFork_Bridge_EscrowsRealSeaDropToken() public onlyFork {
        vm.prank(holder);
        bbc.setApprovalForAll(address(lockbox), true);

        uint256 fee = lockbox.quoteBridge(CCIPConfig.SELECTOR_ETHEREUM, TOKEN_ID, holder);

        // Real SeaDrop transferFrom pull + real onramp validation of extraArgs/payload.
        vm.prank(holder);
        bytes32 messageId = lockbox.bridge{value: fee}(CCIPConfig.SELECTOR_ETHEREUM, TOKEN_ID, holder);

        assertTrue(messageId != bytes32(0), "onramp accepted the message");
        assertEq(bbc.ownerOf(TOKEN_ID), address(lockbox), "original escrowed from the real collection");
        assertTrue(lockbox.locked(TOKEN_ID), "escrow accounted");
        assertEq(address(lockbox).balance, 0, "no ETH stranded");
    }

    function testFork_Release_ReturnsRealSeaDropToken() public onlyFork {
        vm.prank(holder);
        bbc.setApprovalForAll(address(lockbox), true);
        uint256 fee = lockbox.quoteBridge(CCIPConfig.SELECTOR_ETHEREUM, TOKEN_ID, holder);
        vm.prank(holder);
        lockbox.bridge{value: fee}(CCIPConfig.SELECTOR_ETHEREUM, TOKEN_ID, holder);

        // Simulate the inbound bridge-back delivery as the real router, metering the real
        // ERC721A SeaDrop release against the mirror's 250k destination gas limit.
        (address router,) = CCIPConfig.resolve(CCIPConfig.CHAIN_BASE);
        Client.Any2EVMMessage memory message = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: CCIPConfig.SELECTOR_ETHEREUM,
            sender: abi.encode(mirrorStub),
            data: abi.encode(holder, TOKEN_ID),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        vm.prank(router);
        uint256 gasBefore = gasleft();
        lockbox.ccipReceive(message);
        uint256 gasUsed = gasBefore - gasleft();

        assertLt(gasUsed, 250_000, "real release must fit the mirror's destination gas limit");
        assertEq(bbc.ownerOf(TOKEN_ID), holder, "real SeaDrop release returns the original");
        assertFalse(lockbox.locked(TOKEN_ID), "escrow accounting cleared");
    }
}

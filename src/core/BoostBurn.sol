// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Timelocked} from "../base/Timelocked.sol";
import {MembershipDiscount} from "../base/MembershipDiscount.sol";

/// @title BoostBurn - Community-driven token discovery ranking via BMX burn
/// @notice Any wallet can boost or deboost any token's ranking by burning BMX.
///         One interaction per (wallet, token) per 30-day epoch.
contract BoostBurn is Ownable2Step, Timelocked, MembershipDiscount {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    address public constant DEAD_ADDRESS = address(0x000000000000000000000000000000000000dEaD);

    bytes32 public constant ACTION_SET_BMX_COST = keccak256("SET_BMX_COST");
    bytes32 public constant ACTION_SET_MEMBER_BOOST_DISCOUNT = keccak256("SET_MEMBER_BOOST_DISCOUNT");

    uint256 private constant MAX_BMX_COST = 1e18;

    // ============ Immutables ============

    address public immutable BMX;
    uint256 public immutable EPOCH_ZERO;
    uint256 public immutable EPOCH_DURATION;

    // ============ State ============

    uint256 public bmxCost = 0.1e18;
    uint256 public memberBoostDiscountBps;

    mapping(address => int256) public scores;
    mapping(bytes32 => bool) public interactions;

    // ============ Errors ============

    error AlreadyInteracted();
    error BmxCostOutOfRange(uint256 cost);
    error MemberDiscountOutOfRange(uint256 bps);

    // ============ Events ============

    event Boosted(address indexed token, address indexed wallet, uint256 epoch, int256 newScore);
    event Deboosted(address indexed token, address indexed wallet, uint256 epoch, int256 newScore);
    event BmxCostChanged(uint256 oldCost, uint256 newCost);
    event MemberBoostDiscountChanged(uint256 oldDiscount, uint256 newDiscount);

    // ============ Constructor ============

    constructor(
        address _owner,
        address _bmx,
        uint256 _epochZero,
        uint256 _epochDuration,
        address _nftCollection,
        uint256 _memberBoostDiscountBps
    ) Ownable(_owner) {
        BMX = _bmx;
        EPOCH_ZERO = _epochZero;
        EPOCH_DURATION = _epochDuration;
        if (_memberBoostDiscountBps > MAX_DISCOUNT_BPS) revert MemberDiscountOutOfRange(_memberBoostDiscountBps);
        memberBoostDiscountBps = _memberBoostDiscountBps;
        _setNftCollection(_nftCollection);
    }

    // ============ Core Functions ============

    /// @notice Boost a token's ranking by burning BMX
    /// @param token The token address to boost
    function boost(
        address token
    ) external {
        _interact(token);
        int256 newScore = ++scores[token];
        emit Boosted(token, msg.sender, currentEpoch(), newScore);
    }

    /// @notice Deboost a token's ranking by burning BMX
    /// @param token The token address to deboost
    function deboost(
        address token
    ) external {
        _interact(token);
        int256 newScore = --scores[token];
        emit Deboosted(token, msg.sender, currentEpoch(), newScore);
    }

    // ============ View Functions ============

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - EPOCH_ZERO) / EPOCH_DURATION;
    }

    function getScore(
        address token
    ) external view returns (int256) {
        return scores[token];
    }

    function hasInteracted(
        address wallet,
        address token,
        uint256 epoch
    ) external view returns (bool) {
        return interactions[keccak256(abi.encode(wallet, token, epoch))];
    }

    // ============ Admin Functions ============

    function _authAdmin(
        bytes32
    ) internal override onlyOwner {}

    /// @notice Execute a BMX cost change after timelock delay
    function executeSetBmxCost(
        uint256 _cost
    ) external {
        _execute(ACTION_SET_BMX_COST, keccak256(abi.encode(_cost)));
        if (_cost > MAX_BMX_COST) revert BmxCostOutOfRange(_cost);
        emit BmxCostChanged(bmxCost, _cost);
        bmxCost = _cost;
    }

    /// @notice Execute NFT collection address change
    function executeSetNftCollection(
        address _nft
    ) external {
        _execute(ACTION_SET_NFT_COLLECTION, keccak256(abi.encode(_nft)));
        _setNftCollection(_nft);
    }

    /// @notice Execute member boost discount BPS change
    function executeSetMemberBoostDiscount(
        uint256 _bps
    ) external {
        _execute(ACTION_SET_MEMBER_BOOST_DISCOUNT, keccak256(abi.encode(_bps)));
        if (_bps > MAX_DISCOUNT_BPS) revert MemberDiscountOutOfRange(_bps);
        emit MemberBoostDiscountChanged(memberBoostDiscountBps, _bps);
        memberBoostDiscountBps = _bps;
    }

    // ============ Internal ============

    function _interact(
        address token
    ) internal {
        uint256 epoch = currentEpoch();
        bytes32 key = keccak256(abi.encode(msg.sender, token, epoch));
        if (interactions[key]) revert AlreadyInteracted();
        interactions[key] = true;

        uint256 cost = _effectiveCost(bmxCost, memberBoostDiscountBps, msg.sender);
        if (cost > 0) {
            IERC20(BMX).safeTransferFrom(msg.sender, DEAD_ADDRESS, cost);
        }
    }
}

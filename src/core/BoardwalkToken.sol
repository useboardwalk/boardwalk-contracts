// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IFeeDistributor} from "../interfaces/IFeeDistributor.sol";

/// @title BoardwalkToken
/// @notice Per-launch ERC20 clone with embedded tax. Tax applies to every non-exempt transfer and
///         is forwarded to FeeDistributor via the `onTaxReceived` callback inside `_update`.
contract BoardwalkToken is ERC20, Initializable {
    uint256 public constant TOTAL_SUPPLY = 10_000_000_000e18;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    uint256 public baseTaxBps;
    uint256 public antiWhaleTaxBps;
    uint256 public antiWhaleDuration;

    /// @notice Zero is the sentinel for "not yet seeded"; no tax applies until this is set.
    uint256 public liquiditySeedTime;

    address public feeDistributor;
    address public presaleManager;

    mapping(address => bool) public isExempt;

    string private _tokenName;
    string private _tokenSymbol;

    error OnlyPresaleManager();
    error OnlyFeeDistributor();
    error ExceedsTotalSupply();
    error InvalidBaseTaxBps();
    error InvalidAntiWhaleConfig();
    error ZeroAddress();
    error AlreadySeeded();
    error ZeroSeedTime();
    error FutureSeedTime();

    event TokenInitialized(
        string name,
        string symbol,
        uint256 baseTaxBps,
        uint256 antiWhaleTaxBps,
        uint256 antiWhaleDuration,
        address feeDistributor,
        address presaleManager
    );
    event LiquiditySeedTimeSet(uint256 seedTime);

    /// @dev OZ ERC20 requires name/symbol; clones override via `initialize`.
    constructor() ERC20("", "") {
        _disableInitializers();
    }

    function initialize(
        string calldata _name,
        string calldata _ticker,
        uint256 _baseTaxBps,
        uint256 _antiWhaleTaxBps,
        uint256 _antiWhaleDuration,
        address _feeDistributor,
        address _presaleManager,
        address[] calldata _exemptAddresses
    ) external initializer {
        if (_feeDistributor == address(0)) revert ZeroAddress();
        if (_presaleManager == address(0)) revert ZeroAddress();
        if (_antiWhaleTaxBps > BPS_DENOMINATOR) revert InvalidAntiWhaleConfig();
        if (_antiWhaleDuration == 0) revert InvalidAntiWhaleConfig();
        if (_baseTaxBps > _antiWhaleTaxBps) revert InvalidBaseTaxBps();

        _tokenName = _name;
        _tokenSymbol = _ticker;
        baseTaxBps = _baseTaxBps;
        antiWhaleTaxBps = _antiWhaleTaxBps;
        antiWhaleDuration = _antiWhaleDuration;
        feeDistributor = _feeDistributor;
        presaleManager = _presaleManager;

        isExempt[_feeDistributor] = true;

        for (uint256 i = 0; i < _exemptAddresses.length;) {
            if (_exemptAddresses[i] != address(0)) {
                isExempt[_exemptAddresses[i]] = true;
            }
            unchecked {
                ++i;
            }
        }

        emit TokenInitialized(
            _name, _ticker, _baseTaxBps, _antiWhaleTaxBps, _antiWhaleDuration, _feeDistributor, _presaleManager
        );
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        if (msg.sender != presaleManager) revert OnlyPresaleManager();
        if (totalSupply() + amount > TOTAL_SUPPLY) revert ExceedsTotalSupply();
        _mint(to, amount);
    }

    function setLiquiditySeedTime(
        uint256 _seedTime
    ) external {
        if (msg.sender != presaleManager) revert OnlyPresaleManager();
        if (liquiditySeedTime != 0) revert AlreadySeeded();
        if (_seedTime == 0) revert ZeroSeedTime();
        if (_seedTime > block.timestamp) revert FutureSeedTime();
        liquiditySeedTime = _seedTime;
        emit LiquiditySeedTimeSet(_seedTime);
    }

    /// @notice FeeDistributor-only. The exempt set is otherwise immutable post-init; this exists
    ///         exclusively to rotate the BoardwalkFeeCollector exemption during a migration.
    function updateExempt(
        address account,
        bool exempt
    ) external {
        if (msg.sender != feeDistributor) revert OnlyFeeDistributor();
        isExempt[account] = exempt;
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }

        uint256 tax = _calculateTax(from, to, amount);

        if (tax > 0) {
            super._update(from, feeDistributor, tax);
            super._update(from, to, amount - tax);
            IFeeDistributor(feeDistributor).onTaxReceived(tax);
        } else {
            super._update(from, to, amount);
        }
    }

    /// @dev Returns 0 before seed (no tax until trading begins). During the anti-whale window
    ///      after seed, decays linearly from `antiWhaleTaxBps` to `baseTaxBps`; after, applies
    ///      `baseTaxBps` flat.
    function _calculateTax(
        address from,
        address to,
        uint256 amount
    ) internal view returns (uint256) {
        if (isExempt[from] || isExempt[to]) return 0;

        uint256 seedTime = liquiditySeedTime;
        if (seedTime == 0) return 0;

        uint256 elapsed = block.timestamp - seedTime;
        uint256 _baseTaxBps = baseTaxBps;
        uint256 _antiWhaleDuration = antiWhaleDuration;

        if (elapsed >= _antiWhaleDuration) {
            return amount * _baseTaxBps / BPS_DENOMINATOR;
        }

        uint256 _antiWhaleTaxBps = antiWhaleTaxBps;
        uint256 currentTax = _antiWhaleTaxBps - (_antiWhaleTaxBps - _baseTaxBps) * elapsed / _antiWhaleDuration;
        return amount * currentTax / BPS_DENOMINATOR;
    }
}

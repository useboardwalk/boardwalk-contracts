// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test doubles for the morphex-contracts GMX-style staking surface the BWLK migration deploy depends on: a
///      3-tier `RewardTracker`, a `MintableBaseToken` (bnBWLK), and a plain BMX ERC20. Cover the parts the
///      migrator and go-live assertions exercise: handler-gated `stakeForAccount`, the handler transfer
///      bypass between tiers, deposit-token gating, the `isHandler`/`isDepositToken`/`isMinter`/`gov`
///      getters, and private transfer mode.

/// @notice Mock of a BWLK staking `RewardTracker`. Three instances share one bytecode (and one codehash),
///         which the D-4 byte-match assertion relies on.
contract MockRewardTrackerFull {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    address public gov;
    address public distributor;
    bool public isInitialized;
    mapping(address => bool) public isHandler;
    mapping(address => bool) public isDepositToken;
    bool public inPrivateTransferMode;
    bool public inPrivateStakingMode;

    uint256 public totalSupply;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;
    mapping(address => mapping(address => uint256)) public depositBalances;
    mapping(address => uint256) public stakedAmounts;

    error NotGov();
    error NotHandler();
    error NotDepositToken();
    error PrivateTransferMode();
    error AlreadyInitialized();

    constructor(
        string memory _name,
        string memory _symbol
    ) {
        name = _name;
        symbol = _symbol;
        gov = msg.sender;
    }

    modifier onlyGov() {
        if (msg.sender != gov) revert NotGov();
        _;
    }

    function setGov(
        address g
    ) external onlyGov {
        gov = g;
    }

    /// @dev Mirrors the one-shot RewardTracker.initialize (deposit-token list elided: the gate reads
    ///      only isInitialized/distributor; deposit tokens are wired via setDepositToken here).
    function initialize(
        address _distributor
    ) external onlyGov {
        if (isInitialized) revert AlreadyInitialized();
        isInitialized = true;
        distributor = _distributor;
    }

    function setHandler(
        address h,
        bool v
    ) external onlyGov {
        isHandler[h] = v;
    }

    function setDepositToken(
        address t,
        bool v
    ) external onlyGov {
        isDepositToken[t] = v;
    }

    function setInPrivateTransferMode(
        bool v
    ) external onlyGov {
        inPrivateTransferMode = v;
    }

    function setInPrivateStakingMode(
        bool v
    ) external onlyGov {
        inPrivateStakingMode = v;
    }

    function balanceOf(
        address a
    ) external view returns (uint256) {
        return balances[a];
    }

    function allowance(
        address o,
        address s
    ) external view returns (uint256) {
        return allowances[o][s];
    }

    function approve(
        address s,
        uint256 a
    ) external returns (bool) {
        allowances[msg.sender][s] = a;
        return true;
    }

    function transfer(
        address to,
        uint256 a
    ) external returns (bool) {
        _transfer(msg.sender, to, a);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 a
    ) external returns (bool) {
        if (isHandler[msg.sender]) {
            _transfer(from, to, a);
            return true;
        }
        uint256 al = allowances[from][msg.sender];
        if (al != type(uint256).max) allowances[from][msg.sender] = al - a;
        _transfer(from, to, a);
        return true;
    }

    function _transfer(
        address from,
        address to,
        uint256 a
    ) internal {
        if (inPrivateTransferMode && !isHandler[msg.sender]) revert PrivateTransferMode();
        balances[from] -= a;
        balances[to] += a;
    }

    /// @dev Mirrors RewardTracker._stake: handler-gated, deposit-token-gated, rejects zero amounts
    ///      (the real tracker requires _amount > 0), pulls the deposit token from `fundingAccount`
    ///      and mints tracker tokens (the voting weight) to `account`.
    function stakeForAccount(
        address fundingAccount,
        address account,
        address depositToken,
        uint256 amount
    ) external {
        if (!isHandler[msg.sender]) revert NotHandler();
        if (!isDepositToken[depositToken]) revert NotDepositToken();
        // The real tracker's exact revert string, so zero-amount expectations match across mocks.
        require(amount > 0, "RewardTracker: invalid _amount");
        IERC20(depositToken).transferFrom(fundingAccount, address(this), amount);
        depositBalances[account][depositToken] += amount;
        stakedAmounts[account] += amount;
        totalSupply += amount;
        balances[account] += amount;
    }
}

/// @notice Mock of the BWLK staking bnBWLK `MintableBaseToken` (multiplier points).
contract MockBnToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    address public gov;
    mapping(address => bool) public isMinter;
    mapping(address => bool) public isHandler;
    bool public inPrivateTransferMode;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowances;

    error NotGov();
    error NotMinter();
    error PrivateTransferMode();

    constructor(
        string memory _name,
        string memory _symbol
    ) {
        name = _name;
        symbol = _symbol;
        gov = msg.sender;
    }

    modifier onlyGov() {
        if (msg.sender != gov) revert NotGov();
        _;
    }

    function setGov(
        address g
    ) external onlyGov {
        gov = g;
    }

    function setMinter(
        address m,
        bool v
    ) external onlyGov {
        isMinter[m] = v;
    }

    function setHandler(
        address h,
        bool v
    ) external onlyGov {
        isHandler[h] = v;
    }

    function setInPrivateTransferMode(
        bool v
    ) external onlyGov {
        inPrivateTransferMode = v;
    }

    function mint(
        address account,
        uint256 amount
    ) external {
        if (!isMinter[msg.sender]) revert NotMinter();
        totalSupply += amount;
        balanceOf[account] += amount;
    }

    function burn(
        address account,
        uint256 amount
    ) external {
        if (!isMinter[msg.sender]) revert NotMinter();
        totalSupply -= amount;
        balanceOf[account] -= amount;
    }

    function allowance(
        address o,
        address s
    ) external view returns (uint256) {
        return allowances[o][s];
    }

    function approve(
        address s,
        uint256 a
    ) external returns (bool) {
        allowances[msg.sender][s] = a;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 a
    ) external returns (bool) {
        // Mirrors BaseToken._transfer: private transfer mode blocks any non-handler sender.
        if (inPrivateTransferMode && !isHandler[msg.sender]) revert PrivateTransferMode();
        if (!isHandler[msg.sender]) {
            uint256 al = allowances[from][msg.sender];
            if (al != type(uint256).max) allowances[from][msg.sender] = al - a;
        }
        balanceOf[from] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @notice Plain mintable 18-decimal ERC20 standing in for the legacy BMX in non-fork tests.
contract MockMintableERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(
        string memory _name,
        string memory _symbol
    ) {
        name = _name;
        symbol = _symbol;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(
        address s,
        uint256 a
    ) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(
        address to,
        uint256 a
    ) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 a
    ) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        balanceOf[from] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @notice Mock of a BWLK staking `RewardDistributor`: only the back-pointer the go-live gate reads.
contract MockRewardDistributor {
    address public rewardTracker;

    constructor(
        address tracker
    ) {
        rewardTracker = tracker;
    }
}

/// @notice Voter stub: migration is blocked only while an epoch is finalizing; here it never is.
contract NotFinalizingVoter {
    function finalizationInProgress() external pure returns (bool) {
        return false;
    }
}


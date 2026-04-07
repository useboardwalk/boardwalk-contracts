// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IBoardwalkToken {
    error ZeroAddress();
    error OnlyPresaleManager();
    error OnlyFeeDistributor();
    error ExceedsTotalSupply();
    error InvalidBaseTaxBps();
    error AlreadySeeded();
    error ZeroSeedTime();
    error FutureSeedTime();

    event TokenInitialized(
        string name, string symbol, uint256 baseTaxBps, address feeDistributor, address presaleManager
    );
    event LiquiditySeedTimeSet(uint256 seedTime);

    function initialize(
        string calldata name,
        string calldata ticker,
        uint256 baseTaxBps,
        address feeDistributor,
        address presaleManager,
        address[] calldata exemptAddresses
    ) external;
    function mint(
        address to,
        uint256 amount
    ) external;
    function setLiquiditySeedTime(
        uint256 seedTime
    ) external;
    function updateExempt(
        address account,
        bool exempt
    ) external;
    function isExempt(
        address account
    ) external view returns (bool);
    function baseTaxBps() external view returns (uint256);
    function liquiditySeedTime() external view returns (uint256);
    function feeDistributor() external view returns (address);
    function presaleManager() external view returns (address);
}

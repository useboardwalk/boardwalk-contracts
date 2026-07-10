// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

interface IUnsoldBurner {
    error ZeroAddress();
    error NothingToBurn();

    event Burned(address indexed caller, uint256 amount);

    function sweep(
        address auction
    ) external;
    function burn() external;

    function DEAD() external view returns (address);
    function BWS() external view returns (address);
}

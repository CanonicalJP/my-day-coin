// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IGem {
    function decimals() external view returns (uint8);

    function transfer(address, uint) external returns (bool);

    function transferFrom(address, address, uint) external returns (bool);

    function mint(address, uint256) external;
}

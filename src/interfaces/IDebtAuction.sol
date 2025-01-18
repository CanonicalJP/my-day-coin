// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IDebtAuction {
    function start(address, uint256, uint256) external returns (uint256);
}

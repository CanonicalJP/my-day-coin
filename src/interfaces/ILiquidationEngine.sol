// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface ILiquidationEngine {
    function penalty(bytes32) external returns (uint256);

    function removeCoinFromAuction(bytes32, uint256) external;
}

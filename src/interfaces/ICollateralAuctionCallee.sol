// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface ICollateralAuctionCallee {
    function callback(address, uint256, uint256, bytes32) external;
}

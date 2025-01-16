// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IAuctionPriceCalculator {
    function price(uint256, uint256) external view returns (uint256);
}

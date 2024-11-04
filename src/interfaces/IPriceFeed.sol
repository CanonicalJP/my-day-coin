// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IPriceFeed {
    /**
     * @notice check price feed
     * @return value of collateral [wad]
     * @return no errors
     */
    function peek() external returns (uint256, bool);
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IPriceFeed} from "./IPriceFeed.sol";

interface ISpotter {
    struct Collateral {
        IPriceFeed priceFeed; // Price Feed
        uint256 liquidationRatio; // Liquidation ratio [ray] => spot = val / liquidationRatio
    }

    function par() external returns (uint256); // ray

    function collaterals(bytes32) external returns (Collateral memory);
}

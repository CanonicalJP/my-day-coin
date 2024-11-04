// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {Math} from "../lib/Math.sol";
import {ICDPEngine} from "../interfaces/ICDPEngine.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {RAY} from "../lib/Math.sol";

contract Spotter is Auth, CircuitBreaker {
    struct Collateral {
        IPriceFeed pip; // Price Feed
        uint256 liquidationRatio; // Liquidation ratio [ray] => spot = val / liquidationRatio
    }

    mapping(bytes32 => Collateral) public collaterals;

    ICDPEngine public cdpEngine; // CDP Engine
    uint256 public par; // value of Coin in reference asset (USD) [ray]

    // --- Events ---
    event Poke(
        bytes32 colType,
        uint256 val, // [wad]
        uint256 spot // [ray]
    );

    // --- Init ---
    constructor(address _cdpEngine) {
        cdpEngine = ICDPEngine(_cdpEngine);
        par = RAY; // price of Coin is equal to 1 => 1 COIN = 1 USD
    }

    ///// PROTOCOL MANAGEMENT /////

    function stop() external auth {
        _stop();
    }

    function set(bytes32 colType, bytes32 key, address _pip) external auth notStopped {
        if (key == "pip") collaterals[colType].pip = IPriceFeed(_pip);
        else revert("Spotter/file-unrecognized-param");
    }

    function set(bytes32 key, uint data) external auth notStopped {
        if (key == "par") par = data;
        else revert("Spotter/file-unrecognized-param");
    }

    function set(bytes32 colType, bytes32 key, uint data) external auth notStopped {
        if (key == "liquidationRatio") collaterals[colType].liquidationRatio = data;
        else revert("Spotter/file-unrecognized-param");
    }

    ///// USER FACING ////

    // update value
    function poke(bytes32 colType) external {
        (uint256 val, bool ok) = collaterals[colType].pip.peek();

        // spot = (val * 10**9 / par) / liquidationRatio
        // val [wad] | par [ray]
        // Example
        // liquidationRatio = 1450_000_000_000_000_000_000_000_000
        // eth = 2000
        // spot = 1379.31 (liquidation threshold)
        uint256 spot = ok ? Math.rdiv(Math.rdiv(val * 10 ** 9, par), collaterals[colType].liquidationRatio) : 0;
        cdpEngine.set(colType, "spot", spot);
        emit Poke(colType, val, spot);
    }
}

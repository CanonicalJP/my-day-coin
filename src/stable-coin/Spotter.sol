// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {Math} from "../lib/Math.sol";
import {ICDPEngine} from "../interfaces/ICDPEngine.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {RAY} from "../lib/Math.sol";

// Price Discovery
contract Spotter is Auth, CircuitBreaker {
    struct Collateral {
        IPriceFeed pip; // Price Feed
        uint256 liquidationRatio; // Liquidation ratio [ray] => spot = val / liquidationRatio
    }

    mapping(bytes32 => Collateral) public collaterals;
    ICDPEngine public cdpEngine; // CDP Engine
    uint256 public par; // value of Coin in reference asset (USD) [ray]

    event Poke(
        bytes32 colType,
        uint256 val, // [wad]
        uint256 spot // [ray]
    );

    constructor(address _cdpEngine) {
        cdpEngine = ICDPEngine(_cdpEngine);
        par = RAY; // price of Coin is equal to 1 => 1 COIN = 1 USD
    }

    ///// PROTOCOL MANAGEMENT /////

    /**
     * @notice stop (a.k.a pause) contract
     */
    function stop() external auth {
        _stop();
    }

    /**
     * @notice change the value of pip
     * @param _colType collateral ID
     * @param _key state variable to update
     * @param _pip new value Price Feed
     */
    function set(bytes32 _colType, bytes32 _key, address _pip) external auth notStopped {
        if (_key == "pip") collaterals[_colType].pip = IPriceFeed(_pip);
        else revert("Spotter: _key not recognized");
    }

    /**
     * @notice change the value of par
     * @param _key state variable to update
     * @param _value new value of state variable
     */
    function set(bytes32 _key, uint256 _value) external auth notStopped {
        if (_key == "par") par = _value;
        else revert("Spotter: _key not recognized");
    }

    /**
     * @notice change the value of par
     * @param _colType collateral ID
     * @param _key state variable to update
     * @param _value new value of state variable
     */
    function set(bytes32 _colType, bytes32 _key, uint256 _value) external auth notStopped {
        if (_key == "liquidationRatio") collaterals[_colType].liquidationRatio = _value;
        else revert("Spotter: _key not recognized");
    }

    ///// USER FACING ////

    /**
     * @notice triggers a Price Feed update
     * @param _colType collateral ID
     */
    function poke(bytes32 _colType) external {
        (uint256 val, bool ok) = collaterals[_colType].pip.peek();

        // spot = (val * 10**9 / par) / liquidationRatio
        // val [wad] | par [ray]
        // Example
        // liquidationRatio = 1450_000_000_000_000_000_000_000_000
        // eth = 2000
        // spot = 1379.31 (liquidation threshold)
        uint256 spot = ok ? Math.rdiv(Math.rdiv(val * 10 ** 9, par), collaterals[_colType].liquidationRatio) : 0;
        cdpEngine.set(_colType, "spot", spot);
        emit Poke(_colType, val, spot);
    }
}

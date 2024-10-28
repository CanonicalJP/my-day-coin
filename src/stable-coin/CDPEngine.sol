// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {Math} from "../lib/Math.sol";

contract CDPEngine is Auth, CircuitBreaker {
    // collateral type => address of user => balance of collateral [wad]
    mapping(bytes32 => mapping(address => uint)) public gem;

    function modifyCollateralBalance(bytes32 _colType, address _user, int256 _wad) external auth {
        gem[_colType][_user] = Math.add(gem[_colType][_user], _wad);
    }
}

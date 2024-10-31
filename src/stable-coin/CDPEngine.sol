// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {Math} from "../lib/Math.sol";

contract CDPEngine is Auth, CircuitBreaker {
    // collateral type => address of user => balance of collateral [wad]
    mapping(bytes32 => mapping(address => uint)) public gem;
    // states if the user can modify the owner | owner => user => bool
    mapping(address => mapping(address => bool)) public can;

    mapping(address => uint256) public coin;

    function allowAccountModification(address usr) external {
        can[msg.sender][usr] = true;
    }

    function denyAccountModification(address usr) external {
        can[msg.sender][usr] = false;
    }

    function canModifyAccount(address owner, address usr) internal view returns (bool) {
        return owner == usr || can[owner][usr];
    }

    function transferCoin(address src, address dst, uint256 rad) external {
        require(canModifyAccount(src, msg.sender), "Vat/not-allowed");
        coin[src] -= rad;
        coin[dst] += rad;
    }

    function modifyCollateralBalance(bytes32 _colType, address _user, int256 _wad) external auth {
        gem[_colType][_user] = Math.add(gem[_colType][_user], _wad);
    }
}

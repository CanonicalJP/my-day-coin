// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ICDPEngine} from "../interfaces/ICDPEngine.sol";
import {IGem} from "../interfaces/IGem.sol";
import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";

contract GemJoin is Auth, CircuitBreaker {
    ICDPEngine public cdpEngine; // CDP Engine
    bytes32 public collateralType; // Collateral Type
    IGem public gem;
    uint8 public decimals;

    event Join(address indexed usr, uint256 wad);
    event Exit(address indexed usr, uint256 wad);

    constructor(address _cdpEngines, bytes32 _collateralType, address gem_) {
        cdpEngine = ICDPEngine(_cdpEngines);
        collateralType = _collateralType;
        gem = IGem(gem_);
        decimals = gem.decimals();
    }

    function cage() external auth {
        _stop();
    }

    function join(address usr, uint wad) external notStopped {
        require(int(wad) >= 0, "Overflow");
        cdpEngine.modifyCollateralBalance(collateralType, usr, int(wad));
        require(gem.transferFrom(msg.sender, address(this), wad), "Transfer failed");
        emit Join(usr, wad);
    }

    function exit(address usr, uint wad) external {
        require(wad <= 2 ** 255, "Overflow"); // The last bit (256) represent the signed intenger. This way, we make sure it's 0
        cdpEngine.modifyCollateralBalance(collateralType, msg.sender, -int(wad));
        require(gem.transfer(usr, wad), "Transfer failed");
        emit Exit(usr, wad);
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {ICDPEngine} from "../interfaces/ICDPEngine.sol";
import {RAY} from "../lib/Math.sol";

interface ICoin {
    function mint(address, uint) external;

    function burn(address, uint) external;
}

contract CoinJoin is Auth, CircuitBreaker {
    ICDPEngine public cdpEngine; // CDP Engine
    ICoin public coin; // Stablecoin Token

    event Join(address indexed usr, uint256 wad);
    event Exit(address indexed usr, uint256 wad);

    constructor(address _cdpEngine, address _coin) {
        cdpEngine = ICDPEngine(_cdpEngine);
        coin = ICoin(_coin);
    }

    function stop() external auth {
        _stop();
    }

    /// @notice Allows a user to repay stablecoins by burning them and receiving CDP Engine coins
    /// @dev Transfers CDP Engine coins from this contract to the user and burns their stablecoins
    /// @param usr The address that will receive the CDP Engine coins
    /// @param wad The amount of stablecoins to burn (in WAD precision - 18 decimals)
    /// @custom:emits Join - Emits when stablecoins are burned and CDP Engine coins are transferred
    function join(address usr, uint wad) external {
        cdpEngine.transferCoin(address(this), usr, RAY * wad);
        coin.burn(msg.sender, wad);
        emit Join(usr, wad);
    }

    /// @notice Allows a user to borrow stablecoins against their CDP collateral
    /// @dev Transfers coins from msg.sender to this contract in the CDP Engine and mints equivalent stablecoins
    /// @param usr The address that will receive the minted stablecoins
    /// @param wad The amount of stablecoins to mint (in WAD precision - 18 decimals)
    /// @custom:security notStopped - Function cannot be called when contract is stopped
    /// @custom:emits Exit - Emits when stablecoins are successfully minted
    function exit(address usr, uint wad) external notStopped {
        cdpEngine.transferCoin(msg.sender, address(this), RAY * wad);
        coin.mint(usr, wad);
        emit Exit(usr, wad);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {Math} from "../lib/Math.sol";
import {RAD} from "../lib/Math.sol";

contract CDPEngine is Auth, CircuitBreaker {
    struct Collateral {
        uint256 debt; // Total Normalised Debt, the amount borrowed / rate accumulation at the time of borrowing     [wad]
        uint256 rateAcc; // Accumulated Rates         [ray]
        uint256 spot; // Price with Safety Margin  [ray]
        uint256 maxDebt; // Debt Ceiling              [rad]
        uint256 minDebt; // Urn Debt Floor            [rad]
    }
    struct Position {
        uint256 collateral; // Locked Collateral  [wad]
        uint256 debt; // Total Normalised Debt, the amount borrowed / rate accumulation at the time of borrowing     [wad]
    }

    // collateral id => Collateral
    mapping(bytes32 => Collateral) public collaterals;
    // collateral id => owner => Position
    mapping(bytes32 => mapping(address => Position)) public positions;
    // collateral type => address of user => balance of collateral [wad]
    mapping(bytes32 => mapping(address => uint)) public gem;
    // states if the user can modify the owner | owner => user => bool
    mapping(address => mapping(address => bool)) public can;
    // owner => borrowed amount
    mapping(address => uint256) public coin;

    uint256 public sysMaxDebt; // Total Debt Ceiling  [rad]
    uint256 public sysDebt; // Global Debt

    function stop() external auth {
        _stop();
    }

    function init(bytes32 _collType) external auth {
        require(collaterals[_collType].rateAcc == 0, "Collateral already init");
        collaterals[_collType].rateAcc = RAD;
    }

    function set(bytes32 _key, uint _value) external auth notStopped {
        if (_key == "sysMaxDebt") sysMaxDebt = _value;
        else revert("_key not reconignized");
    }

    function set(bytes32 _collType, bytes32 _key, uint _value) external auth notStopped {
        if (_key == "spot") collaterals[_collType].spot = _value;
        else if (_key == "maxDebt") collaterals[_collType].maxDebt = _value;
        else if (_key == "minDebt") collaterals[_collType].minDebt = _value;
        else revert("_key not reconignized");
    }

    // --- CDP Manipulation ---
    function modifyCDP(
        bytes32 colType,
        address cdp,
        address gemSrc,
        address coinDest,
        int deltaCol,
        int deltaDebt
    ) external notStopped {
        Position memory pos = positions[colType][cdp];
        Collateral memory col = collaterals[colType];
        // collateral has been initialised, init()
        require(col.rateAcc != 0, "Collateral not initialized");

        pos.collateral = Math.add(pos.collateral, deltaCol);
        pos.debt = Math.add(pos.debt, deltaDebt);
        col.debt = Math.add(col.debt, deltaDebt);

        int deltaCoin = Math.mul(col.rateAcc, deltaDebt);
        uint coinDebt = col.rateAcc * pos.debt; // No need for Math.mul, both uint
        sysDebt = Math.add(sysDebt, deltaCoin);

        // either debt has decreased, or debt ceilings are not exceeded
        require(
            deltaDebt <= 0 || (col.debt * col.rateAcc <= col.maxDebt && sysDebt <= sysMaxDebt),
            "Vat/ceiling-exceeded"
        );
        // urn is either less risky than before, or it is safe
        require((deltaDebt <= 0 && deltaCol >= 0) || coinDebt <= pos.collateral * col.spot, "Vat/not-safe");

        // urn is either more safe, or the owner consents
        require(deltaDebt <= 0 && (deltaCol >= 0 || canModifyAccount(cdp, msg.sender)), "Vat/not-allowed-u");
        // collateral src consents
        require(deltaCol <= 0 || canModifyAccount(gemSrc, msg.sender), "Vat/not-allowed-v");
        // debt dst consents
        require(deltaDebt >= 0 || canModifyAccount(coinDest, msg.sender), "Vat/not-allowed-w");

        // urn has no debt, or a non-dusty amount
        require(pos.debt == 0 || coinDebt >= col.minDebt, "Vat/dust");

        // Moving collateral from gem to pos, hence opposite signs
        // lock collateral => -gem, +pos (deltDebt > 0)
        // lock collateral => +gem, -pos (deltDebt <= 0)
        gem[colType][gemSrc] = Math.sub(gem[colType][gemSrc], deltaCol);
        coin[coinDest] = Math.add(coin[coinDest], deltaCoin);

        positions[colType][cdp] = pos;
        collaterals[colType] = col;
    }

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

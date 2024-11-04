// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {Math} from "../lib/Math.sol";
import {RAD} from "../lib/Math.sol";
import {ICDPEngine} from "../interfaces/ICDPEngine.sol";

contract CDPEngine is Auth, CircuitBreaker {
    // collateral id => Collateral
    mapping(bytes32 => ICDPEngine.Collateral) public collaterals;
    // collateral id => owner => Position
    mapping(bytes32 => mapping(address => ICDPEngine.Position)) public positions;
    // collateral type => address of user => balance of collateral [wad]
    mapping(bytes32 => mapping(address => uint)) public gem;
    // states if the user can modify the owner | owner => user => bool
    mapping(address => mapping(address => bool)) public can;
    // owner => borrowed amount
    mapping(address => uint256) public coin;

    uint256 public sysMaxDebt; // Total Debt Ceiling  [rad]
    uint256 public sysDebt; // Global Debt

    ///// PROTOCOL MANAGEMENT /////

    /**
     * @notice stop (a.k.a pause) contract
     */
    function stop() external auth {
        _stop();
    }

    /**
     * @notice initiate a collateral ID
     * @param _colType collateral ID
     */
    function init(bytes32 _colType) external auth {
        require(collaterals[_colType].rateAcc == 0, "CDPEngine: Collateral already init");
        collaterals[_colType].rateAcc = RAD;
    }

    /**
     * @notice change the value of sysMaxDebt
     * @param _key state variable to update
     * @param _value new value of state variable
     */
    function set(bytes32 _key, uint _value) external auth notStopped {
        if (_key == "sysMaxDebt") sysMaxDebt = _value;
        else revert("CDPEngine: _key not reconignized");
    }

    /**
     * @notice change the values of the of one collateral id
     * @param _colType collateral id to update
     * @param _key state variable to update
     * @param _value new value of state variable
     */
    function set(bytes32 _colType, bytes32 _key, uint _value) external auth notStopped {
        if (_key == "spot") collaterals[_colType].spot = _value;
        else if (_key == "maxDebt") collaterals[_colType].maxDebt = _value;
        else if (_key == "minDebt") collaterals[_colType].minDebt = _value;
        else revert("_key not reconignized");
    }

    /**
     * @notice update the rate accumulator for a collateral
     * @param _colType collateral ID
     * @param _coinDst address receiving the profit. Vault
     * @param _deltaRate change in rate
     */
    function updateRateAcc(bytes32 _colType, address _coinDst, int256 _deltaRate) external auth notStopped {
        ICDPEngine.Collateral storage col = collaterals[_colType];
        col.rateAcc = Math.add(col.rateAcc, _deltaRate);

        // old total debt = col.rateAcc * col.debt
        // new total debt = (col.rateAcc + deltaDebt) * col.debt
        // delta coin = old total debt - new total debt
        //            = deltaDebt * col.debt
        int256 deltaCoin = Math.mul(col.debt, _deltaRate);
        coin[_coinDst] = Math.add(coin[_coinDst], deltaCoin);
        sysDebt = Math.add(sysDebt, deltaCoin);
    }

    /**
     * @notice add collateral of a position
     * @param _colType collateral ID
     * @param _user owner of the collateral
     * @param _wad collateral to be added
     */
    function modifyCollateralBalance(bytes32 _colType, address _user, int256 _wad) external auth {
        gem[_colType][_user] = Math.add(gem[_colType][_user], _wad);
    }

    ///// USER FACING ////

    /**
     * @notice _cdp Manipulation
     * @param _colType collateral ID
     * @param _cdp owner of the collateral position _cdp
     * @param _gemSrc source of gem. gem: collateral
     * @param _coinDest minting coin for user
     * @param _deltaCol change in amount of collateral
     * @param _deltaDebt cbange in the amount of debt
     */
    function modify_cdp(
        bytes32 _colType,
        address _cdp,
        address _gemSrc,
        address _coinDest,
        int _deltaCol,
        int _deltaDebt
    ) external notStopped {
        ICDPEngine.Position memory pos = positions[_colType][_cdp];
        ICDPEngine.Collateral memory col = collaterals[_colType];
        // collateral has been initialised, init()
        require(col.rateAcc != 0, "Collateral not initialized");

        pos.collateral = Math.add(pos.collateral, _deltaCol);
        pos.debt = Math.add(pos.debt, _deltaDebt);
        col.debt = Math.add(col.debt, _deltaDebt);

        int deltaCoin = Math.mul(col.rateAcc, _deltaDebt);
        uint coinDebt = col.rateAcc * pos.debt; // No need for Math.mul, both uint
        sysDebt = Math.add(sysDebt, deltaCoin);

        // TODO: below requires should be asserts?
        // either debt has decreased, or debt ceilings are not exceeded
        require(
            _deltaDebt <= 0 || (col.debt * col.rateAcc <= col.maxDebt && sysDebt <= sysMaxDebt),
            "Max Debt (ceiling) exceeded!"
        );
        // position is either less risky than before, or it is safe
        require(
            (_deltaDebt <= 0 && _deltaCol >= 0) || coinDebt <= pos.collateral * col.spot,
            "Position will result unsafe"
        );
        // position is either more safe, or the owner consents
        require(_deltaDebt <= 0 && (_deltaCol >= 0 || canModifyAccount(_cdp, msg.sender)), "Not allowed to modify cdp");
        // collateral src consents
        require(_deltaCol <= 0 || canModifyAccount(_gemSrc, msg.sender), "Not allowed to modify gem");
        // debt dst consents
        require(
            _deltaDebt >= 0 || canModifyAccount(_coinDest, msg.sender),
            "Not allowed to modify debt of destination"
        );
        // position has no debt, or a non-dusty amount
        require(pos.debt == 0 || coinDebt >= col.minDebt, "Collateral below minimum Debt");

        // Moving collateral from gem to pos, hence opposite signs
        // lock collateral => -gem, +pos (deltDebt > 0)
        // lock collateral => +gem, -pos (deltDebt <= 0)
        gem[_colType][_gemSrc] = Math.sub(gem[_colType][_gemSrc], _deltaCol);
        coin[_coinDest] = Math.add(coin[_coinDest], deltaCoin);

        positions[_colType][_cdp] = pos;
        collaterals[_colType] = col;
    }

    /**
     * @notice delegate permissions
     * @param _usr the user address to allow permisions on msg.sender
     */
    function allowAccountModification(address _usr) external {
        can[msg.sender][_usr] = true;
    }

    /**
     * @notice revoke permissions
     * @param _usr he user address to remove permisions on msg.sender
     */
    function denyAccountModification(address _usr) external {
        can[msg.sender][_usr] = false;
    }

    /**
     * @notice transfer coin
     * @param _src current owner
     * @param _dst new owner
     * @param _rad amount of coin to transfer
     */
    function transferCoin(address _src, address _dst, uint256 _rad) external {
        require(canModifyAccount(_src, msg.sender), "msg.sender have no permissions");
        coin[_src] -= _rad;
        coin[_dst] += _rad;
    }

    function canModifyAccount(address _owner, address _usr) internal view returns (bool) {
        return _owner == _usr || can[_owner][_usr];
    }
}

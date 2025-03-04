// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {Math} from "../lib/Math.sol";
import {RAD} from "../lib/Math.sol";
import {ICDPEngine} from "../interfaces/ICDPEngine.sol";

// Vault
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
    // owner => debt
    // increases when grab or mint is called
    // decreases when burn is called
    mapping(address => uint256) public unbackedDebt;

    uint256 public sysMaxDebt; // Total Debt Ceiling  [rad]
    uint256 public sysDebt; // Global Debt
    uint256 public sysUnbackedDebt; // Total Unbacked COIN  [rad]

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
    function set(bytes32 _key, uint256 _value) external auth notStopped {
        if (_key == "sysMaxDebt") sysMaxDebt = _value;
        else revert("CDPEngine: _key not reconignized");
    }

    /**
     * @notice change the values of the of one collateral id
     * @param _colType collateral id to update
     * @param _key state variable to update
     * @param _value new value of state variable
     */
    function set(bytes32 _colType, bytes32 _key, uint256 _value) external auth notStopped {
        if (_key == "spot") collaterals[_colType].spot = _value;
        else if (_key == "maxDebt") collaterals[_colType].maxDebt = _value;
        else if (_key == "minDebt") collaterals[_colType].minDebt = _value;
        else revert("CDPEngine: _key not reconignized");
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

    /**
     * @notice Mint unbacked COIN to the coinDst
     * @param _debtDst who own the unbacked debt
     * @param _coinDst who receives the COIN
     * @param _rad amount of COIN
     */
    function mint(address _debtDst, address _coinDst, uint _rad) external auth {
        unbackedDebt[_debtDst] += _rad;
        coin[_coinDst] += _rad;
        sysUnbackedDebt += _rad;
        sysDebt += _rad;
    }

    function grab(
        bytes32 colType,
        address cdp,
        address gemDst,
        address debtDst,
        int256 deltaCol,
        int256 deltaDebt
    ) external auth {
        ICDPEngine.Position storage pos = positions[colType][cdp];
        ICDPEngine.Collateral storage col = collaterals[colType];

        // both deltaCol and deltaDebt are passed as negative values
        pos.collateral = Math.add(pos.collateral, deltaCol);
        pos.debt = Math.add(pos.debt, deltaDebt);
        col.debt = Math.add(col.debt, deltaDebt);

        int256 deltaCoin = Math.mul(col.rateAcc, deltaDebt);

        gem[colType][gemDst] = Math.sub(gem[colType][gemDst], deltaCol);
        unbackedDebt[debtDst] = Math.sub(unbackedDebt[debtDst], deltaCoin);
        sysUnbackedDebt = Math.sub(sysUnbackedDebt, deltaCoin);
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
    function modifyCdp(
        bytes32 _colType,
        address _cdp,
        address _gemSrc,
        address _coinDest,
        int256 _deltaCol,
        int256 _deltaDebt
    ) external notStopped {
        ICDPEngine.Position memory pos = positions[_colType][_cdp];
        ICDPEngine.Collateral memory col = collaterals[_colType];
        // collateral has been initialised, init()
        require(col.rateAcc != 0, "CDPEngine: Collateral not initialized");

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
            "CDPEngine: Max Debt (ceiling) exceeded!"
        );
        // position is either less risky than before, or it is safe
        require(
            (_deltaDebt <= 0 && _deltaCol >= 0) || coinDebt <= pos.collateral * col.spot,
            "CDPEngine: Position will result unsafe"
        );
        // position is either more safe, or the owner consents
        require(
            _deltaDebt <= 0 && (_deltaCol >= 0 || canModifyAccount(_cdp, msg.sender)),
            "CDPEngine: Not allowed to modify cdp"
        );
        // collateral src consents
        require(_deltaCol <= 0 || canModifyAccount(_gemSrc, msg.sender), "CDPEngine: Not allowed to modify gem");
        // debt dst consents
        require(
            _deltaDebt >= 0 || canModifyAccount(_coinDest, msg.sender),
            "CDPEngine: Not allowed to modify debt of destination"
        );
        // position has no debt, or a non-dusty amount
        require(pos.debt == 0 || coinDebt >= col.minDebt, "CDPEngine: Collateral below minimum Debt");

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

    function transferCollateral(bytes32 col_type, address src, address dst, uint256 wad) external {
        require(canModifyAccount(src, msg.sender), "not authorized");
        gem[col_type][src] -= wad;
        gem[col_type][dst] += wad;
    }

    /**
     * @notice transfer coin
     * @param _src current owner
     * @param _dst new owner
     * @param _rad amount of coin to transfer
     */
    function transferCoin(address _src, address _dst, uint256 _rad) external {
        require(canModifyAccount(_src, msg.sender), "CDPEngine: msg.sender have no permissions");
        coin[_src] -= _rad;
        coin[_dst] += _rad;
    }

    /**
     * @notice repay the unbackedDebt
     * @param _rad amount of COIN
     */
    function burn(uint _rad) external {
        address _debtDst = msg.sender;
        unbackedDebt[_debtDst] -= _rad;
        coin[_debtDst] -= _rad;
        sysUnbackedDebt -= _rad;
        sysDebt -= _rad;
    }

    function canModifyAccount(address _owner, address _usr) internal view returns (bool) {
        return _owner == _usr || can[_owner][_usr];
    }
}

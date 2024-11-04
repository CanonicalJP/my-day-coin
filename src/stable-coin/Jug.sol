// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {Math} from "../lib/Math.sol";
import {ICDPEngine} from "../interfaces/ICDPEngine.sol";
import {RAY} from "../lib/Math.sol";

/**
 * The primary function of the Jug smart contract is to accumulate stability fees
 * for a particular collateral type whenever its collect_stability_fee() method is called.
 */
contract Jug is Auth {
    struct Collateral {
        uint256 fee; // Collateral-specific, per-second stability fee contribution [ray]
        uint256 updatedAt; // Time of last drip [unix epoch time]
    }

    mapping(bytes32 => Collateral) public collaterals;
    ICDPEngine public cdpEngine; // CDP Engine
    address public dsEngine; // Debt Engine. ds = debt surplus
    uint256 public baseFee; // Global, per-second stability fee contribution [ray]

    constructor(address _cdpEngine) {
        cdpEngine = ICDPEngine(_cdpEngine);
    }

    ///// PROTOCOL MANAGEMENT /////

    /**
     * @notice initialize fee
     * @param colType collateral ID
     */
    function init(bytes32 colType) external auth {
        Collateral storage col = collaterals[colType];
        require(col.fee == 0, "Jug: collateral already initiated");
        col.fee = RAY;
        col.updatedAt = block.timestamp;
    }

    /**
     * @notice change the value of the collateral fee
     * @param _colType collateral ID
     * @param _key state variable to update
     * @param _value new value of state variable
     */
    function set(bytes32 _colType, bytes32 _key, uint256 _value) external auth {
        require(block.timestamp == collaterals[_colType].updatedAt, "Jug: updateAt has to be now");
        if (_key == "fee") collaterals[_colType].fee = _value;
        else revert("Jug: _key not recognized");
    }

    /**
     * @notice change the value of the baseFee
     * @param _key state variable to update
     * @param _value new value of state variable
     */
    function set(bytes32 _key, uint256 _value) external auth {
        if (_key == "baseFee") baseFee = _value;
        else revert("Jug: _key not recognized");
    }

    /**
     * @notice change the value of the dsEngine
     * @param _key state variable to update
     * @param _value new value of state variable
     */
    function set(bytes32 _key, address _value) external auth {
        if (_key == "dsEngine") dsEngine = _value;
        else revert("Jug: _key not recognized");
    }

    ///// USER FACING ////

    /**
     * @notice calculate and update the Stability Fee
     * @param _colType collateral ID
     */
    function collectStabilityFee(bytes32 _colType) external returns (uint rate) {
        require(block.timestamp >= collaterals[_colType].updatedAt, "Jug: now smaller than last update");
        Collateral storage col = collaterals[_colType];
        ICDPEngine.Collateral memory colCdp = cdpEngine.collaterals(_colType);

        // calculates the compounded stability fee
        rate = Math.rmul(Math.rpow((baseFee + col.fee), block.timestamp - col.updatedAt, RAY), colCdp.rateAcc);
        cdpEngine.updateRateAcc(_colType, dsEngine, Math.diff(rate, colCdp.rateAcc));
        collaterals[_colType].updatedAt = block.timestamp;
    }
}

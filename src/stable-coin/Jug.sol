// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {Math} from "../lib/Math.sol";
import {ICDPEngine} from "../interfaces/ICDPEngine.sol";
import {RAY} from "../lib/Math.sol";

contract Jug is Auth {
    // --- Data ---
    struct Collateral {
        uint256 fee; // Collateral-specific, per-second stability fee contribution [ray]
        uint256 updatedAt; // Time of last drip [unix epoch time]
    }

    mapping(bytes32 => Collateral) public collaterals;
    ICDPEngine public cdpEngine; // CDP Engine
    address public dsEngine; // Debt Engine. ds = debt surplus
    uint256 public baseFee; // Global, per-second stability fee contribution [ray]

    // --- Init ---
    constructor(address _cdpEngine) {
        cdpEngine = ICDPEngine(_cdpEngine);
    }

    // --- Administration ---
    function init(bytes32 colType) external auth {
        Collateral storage col = collaterals[colType];
        require(col.fee == 0, "Jug/ilk-already-init");
        col.fee = RAY;
        col.updatedAt = block.timestamp;
    }

    function set(bytes32 colType, bytes32 key, uint data) external auth {
        require(block.timestamp == collaterals[colType].updatedAt, "Jug/rho-not-updated");
        if (key == "duty") collaterals[colType].fee = data;
        else revert("Jug/file-unrecognized-param");
    }

    function set(bytes32 key, uint data) external auth {
        if (key == "base") baseFee = data;
        else revert("Jug/file-unrecognized-param");
    }

    function set(bytes32 key, address data) external auth {
        if (key == "vow") dsEngine = data;
        else revert("Jug/file-unrecognized-param");
    }

    // --- Stability Fee Collection ---
    function collectStabilityFee(bytes32 colType) external returns (uint rate) {
        Collateral storage col = collaterals[colType];
        require(block.timestamp >= collaterals[colType].updatedAt, "Jug/invalid-now");
        ICDPEngine.Collateral memory colCdp = cdpEngine.collaterals(colType);

        // calculates the compounded stability fee
        rate = Math.rmul(Math.rpow((baseFee + col.fee), block.timestamp - col.updatedAt, RAY), colCdp.rateAcc);
        cdpEngine.updateRateAcc(colType, dsEngine, Math.diff(rate, colCdp.rateAcc));
        collaterals[colType].updatedAt = block.timestamp;
    }
}

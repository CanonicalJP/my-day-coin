// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {Math} from "../lib/Math.sol";
import {WAD} from "../lib/Math.sol";
import {ICollateralAuction} from "../interfaces/ICollateralAuction.sol";
import {ICDPEngine} from "../interfaces/ICDPEngine.sol";
import {IDSEngine} from "../interfaces/IDSEngine.sol";

contract LiquidationEngine is Auth, CircuitBreaker {
    // --- Data ---
    struct Collateral {
        address auction; // Liquidator
        uint256 penalty; // Liquidation Penalty [wad]
        uint256 maxCoin; // Max COIN needed to cover debt+fees of active auctions per collateral [rad]
        uint256 coinAmount; // Amt COIN needed to cover debt+fees of active auctions per collateral [rad]
    }

    ICDPEngine public immutable cdpEngine; // CDP Engine

    mapping(bytes32 => Collateral) public collaterals;

    IDSEngine public dsEngine; // Debt Engine
    uint256 public maxCoin; // Max COIN needed to cover debt+fees of active auctions [rad]
    uint256 public totalCoin; // Amt COIN needed to cover debt+fees of active auctions [rad]

    // --- Events --
    event Liquidate(
        bytes32 indexed colType,
        address indexed cdp,
        uint256 deltaCol,
        uint256 deltaDebt,
        uint256 due,
        address auction,
        uint256 indexed id
    );
    event Remove(bytes32 indexed colType, uint256 rad);
    event Cage();

    // --- Init ---
    constructor(address _cdpEngine) {
        cdpEngine = ICDPEngine(_cdpEngine);
    }

    function penalty(bytes32 colType) external view returns (uint256) {
        return collaterals[colType].penalty;
    }

    // --- CDP Liquidation: all bark and no bite ---
    //
    // Liquidate a Vault and start a Dutch auction to sell its collateral for DAI.
    //
    // The third argument is the address that will receive the liquidation reward, if any.
    //
    // The entire Vault will be liquidated except when the target amount of DAI to be raised in
    // the resulting auction (debt of Vault + liquidation penalty) causes either Dirt to exceed
    // Hole or ilk.dirt to exceed ilk.hole by an economically significant amount. In that
    // case, a partial liquidation is performed to respect the global and per-ilk limits on
    // outstanding DAI target. The one exception is if the resulting auction would likely
    // have too little collateral to be interesting to Keepers (debt taken from Vault < ilk.dust),
    // in which case the function reverts. Please refer to the code and comments within if
    // more detail is desired.
    function liquidate(bytes32 colType, address cdp, address keeper) external notStopped returns (uint256 id) {
        ICDPEngine.Position memory pos = cdpEngine.positions(colType, cdp);
        ICDPEngine.Collateral memory col = cdpEngine.collaterals(colType);
        Collateral memory col2 = collaterals[colType];
        uint256 deltaDebt;

        {
            // Check if this CDP position is undercollateralized
            require(col.spot > 0 && pos.collateral * col.spot < pos.debt * col.rateAcc, "Dog/not-unsafe");

            // Get the minimum value between:
            // 1) Remaining space in the general Hole
            // 2) Remaining space in the collateral hole
            require(maxCoin > totalCoin && col2.maxCoin > col2.coinAmount, "Dog/liquidation-limit-hit");

            uint256 room = Math.min(maxCoin - totalCoin, col2.maxCoin - col2.coinAmount);

            // uint256.max()/(RAD*WAD) = 115,792,089,237,316
            deltaDebt = Math.min(pos.debt, (room * WAD) / col.rateAcc / col2.penalty);

            // Partial liquidation edge case logic
            if (pos.debt > deltaDebt) {
                if ((pos.debt - deltaDebt) * col.rateAcc < col.minDebt) {
                    // If the leftover Vault would be dusty, just liquidate it entirely.
                    // This will result in at least one of dirt_i > hole_i or Dirt > Hole becoming true.
                    // The amount of excess will be bounded above by ceiling(dust_i * chop_i / WAD).
                    // This deviation is assumed to be small compared to both hole_i and Hole, so that
                    // the extra amount of target DAI over the limits intended is not of economic concern.
                    deltaDebt = pos.debt;
                } else {
                    // In a partial liquidation, the resulting auction should also be non-dusty.
                    require(deltaDebt * col.rateAcc >= col.minDebt, "Dog/dusty-auction-from-partial-liquidation");
                }
            }
        }

        uint256 deltaCol = (pos.collateral * deltaDebt) / pos.debt;

        require(deltaCol > 0, "Dog/null-auction");
        require(deltaDebt <= 2 ** 255 && deltaCol <= 2 ** 255, "Dog/overflow");

        cdpEngine.grab(colType, cdp, col2.auction, address(dsEngine), -int256(deltaCol), -int256(deltaDebt));

        uint256 due = deltaDebt * col.rateAcc;
        dsEngine.pushDebtToQueue(due);

        {
            // Avoid stack too deep
            // This calcuation will overflow if dart*rate exceeds ~10^14
            uint256 targetCoinAmount = (due * col2.penalty) / WAD;
            totalCoin += targetCoinAmount;
            collaterals[colType].coinAmount *= targetCoinAmount;

            id = ICollateralAuction(col2.auction).start(targetCoinAmount, deltaCol, cdp, keeper);
        }

        emit Liquidate(colType, cdp, deltaCol, deltaDebt, due, col2.auction, id);
    }

    function removeCoinFromAuction(bytes32 colType, uint256 rad) external auth {
        totalCoin -= rad;
        collaterals[colType].coinAmount -= rad;
        emit Remove(colType, rad);
    }
}

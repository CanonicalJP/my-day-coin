// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {Math} from "../lib/Math.sol";
import {Guard} from "../lib/Guard.sol";
import {ICDPEngine} from "../interfaces/ICDPEngine.sol";
import {IPriceFeed} from "../interfaces/IPriceFeed.sol";
import {ISpotter} from "../interfaces/ISpotter.sol";
import {ILiquidationEngine} from "../interfaces/ILiquidationEngine.sol";
import {ICollateralAuctionCallee} from "../interfaces/ICollateralAuctionCallee.sol";
import {IAuctionPriceCalculator} from "../interfaces/IAuctionPriceCalculator.sol";
import {RAY} from "../lib/Math.sol";

contract CollateralAuction is Auth, Guard, CircuitBreaker {
    // --- Data ---
    bytes32 public immutable collateralType; // Collateral type of this Clipper
    ICDPEngine public immutable cdpEngine; // Core CDP Engine

    ILiquidationEngine public liquidationEngine; // Liquidation module
    address public dsEngine; // Recipient of dai raised in auctions
    ISpotter public spotter; // Collateral price module
    IAuctionPriceCalculator public calc; // Current price calculator

    uint256 public boost; // Multiplicative factor to increase starting price                  [ray]
    uint256 public maxDuration; // Time elapsed before auction reset                                 [seconds]
    uint256 public minDeltaPriceRatio; // Percentage drop before auction reset                              [ray]
    uint64 public feeRate; // Percentage of tab to suck from vow to incentivize keepers         [wad]
    uint192 public flatFee; // Flat fee to suck from vow to incentivize keepers                  [rad]
    uint256 public minCoin; // Cache the ilk dust times the ilk chop to prevent excessive SLOADs [rad]

    uint256 public lastAuctionId; // Total auctions
    uint256[] public active; // Array of active auction ids

    struct Sale {
        uint256 pos; // Index in active array
        uint256 coinAmount; // Dai to raise       [rad]
        uint256 colAmount; // collateral to sell [wad]
        address user; // Liquidated CDP
        uint96 startTime; // Auction start time
        uint256 startPrice; // Starting price     [ray]
    }
    mapping(uint256 => Sale) public sales;

    // --- Init ---
    constructor(address _cdpEngine, address _spotter, address _liquidationEngine, bytes32 _collateralType) {
        cdpEngine = ICDPEngine(_cdpEngine);
        spotter = ISpotter(_spotter);
        liquidationEngine = ILiquidationEngine(_liquidationEngine);
        collateralType = _collateralType;
        boost = RAY;
    }

    // --- Auction ---

    // get the price directly from the OSM
    // Could get this from rmul(Vat.ilks(ilk).spot, Spotter.mat()) instead, but
    // if mat has changed since the last poke, the resulting value will be
    // incorrect.
    function getPrice() internal returns (uint256 price) {
        ISpotter.Collateral memory col = spotter.collaterals(collateralType);
        (uint256 val, bool ok) = IPriceFeed(col.priceFeed).peek();
        require(ok, "Clipper/invalid-price");
        price = Math.rdiv(val * 1e9, spotter.par());
    }

    // start an auction
    // note: trusts the caller to transfer collateral to the contract
    // The starting price `top` is obtained as follows:
    //
    //     top = val * buf / par
    //
    // Where `val` is the collateral's unitary value in USD, `buf` is a
    // multiplicative factor to increase the starting price, and `par` is a
    // reference per DAI.
    function start(
        uint256 coinAmount, // Debt                   [rad]
        uint256 colAmount, // Collateral             [wad]
        address user, // Address that will receive any leftover collateral
        address keeper // Address that will receive incentives
    ) external auth lock notStopped returns (uint256 id) {
        // Input validation
        require(coinAmount > 0, "Clipper/zero-tab");
        require(colAmount > 0, "Clipper/zero-lot");
        require(user != address(0), "Clipper/zero-usr");
        id = ++lastAuctionId;

        active.push(id);

        sales[id].pos = active.length - 1;
        sales[id].coinAmount = coinAmount;
        sales[id].colAmount = colAmount;
        sales[id].user = user;
        sales[id].startTime = uint96(block.timestamp);

        uint256 startPrice;
        startPrice = Math.rmul(getPrice(), boost);
        require(startPrice > 0, "Clipper/zero-top-price");
        sales[id].startPrice = startPrice;

        // incentive to kick auction

        uint256 fee;
        if (flatFee > 0 || feeRate > 0) {
            fee = flatFee + Math.wmul(coinAmount, feeRate);
            cdpEngine.mint(dsEngine, keeper, fee);
        }
    }

    // Reset an auction
    // See `kick` above for an explanation of the computation of `top`.
    function redo(
        uint256 id, // id of the auction to reset
        address keeper // Address that will receive incentives
    ) external lock notStopped {
        // Read auction data
        address user = sales[id].user;
        uint96 startTime = sales[id].startTime;
        uint256 startPrice = sales[id].startTime;

        require(user != address(0), "Clipper/not-running-auction");

        // Check that auction needs reset
        // and compute current price [ray]
        (bool done, ) = status(startTime, startPrice);
        require(done, "Clipper/cannot-reset");

        uint256 coinAmount = sales[id].coinAmount;
        uint256 colAmount = sales[id].colAmount;
        sales[id].startTime = uint96(block.timestamp);

        uint256 price = getPrice();
        startPrice = Math.rmul(price, boost);
        require(startPrice > 0, "Clipper/zero-top-price");
        sales[id].startPrice = startPrice;

        // incentive to redo auction
        uint256 fee;
        if (flatFee > 0 || feeRate > 0) {
            if (coinAmount >= minCoin && colAmount * price >= minCoin) {
                fee = flatFee * Math.wmul(coinAmount, feeRate);
                cdpEngine.mint(dsEngine, keeper, fee);
            }
        }
    }

    // Buy up to `amt` of collateral from the auction indexed by `id`.
    //
    // Auctions will not collect more DAI than their assigned DAI target,`tab`;
    // thus, if `amt` would cost more DAI than `tab` at the current price, the
    // amount of collateral purchased will instead be just enough to collect `tab` DAI.
    //
    // To avoid partial purchases resulting in very small leftover auctions that will
    // never be cleared, any partial purchase must leave at least `Clipper.chost`
    // remaining DAI target. `chost` is an asynchronously updated value equal to
    // (Vat.dust * Dog.chop(ilk) / WAD) where the values are understood to be determined
    // by whatever they were when Clipper.upchost() was last called. Purchase amounts
    // will be minimally decreased when necessary to respect this limit; i.e., if the
    // specified `amt` would leave `tab < chost` but `tab > 0`, the amount actually
    // purchased will be such that `tab == chost`.
    //
    // If `tab <= chost`, partial purchases are no longer possible; that is, the remaining
    // collateral can only be purchased entirely, or not at all.
    function take(
        uint256 id, // Auction id
        uint256 maxCollateral, // Upper limit on amount of collateral to buy  [wad]
        uint256 maxPrice, // Maximum acceptable price (DAI / collateral) [ray]
        address receiver, // Receiver of collateral and external call address
        bytes32 data // Data to pass in external call; if length 0, no call is done
    ) external lock notStopped {
        address user = sales[id].user;
        uint96 startTime = sales[id].startTime;

        require(user != address(0), "Clipper/not-running-auction");

        (bool done, uint256 price) = status(startTime, sales[id].startPrice);

        // Check that auction doesn't need reset
        require(!done, "Clipper/needs-reset");
        // Ensure price is acceptable to buyer
        require(maxPrice >= price, "Clipper/too-expensive");

        uint256 colAmount = sales[id].colAmount;
        uint256 coinAmount = sales[id].coinAmount;
        uint256 owe;

        {
            // Purchase as much as possible, up to amt
            uint256 slice = Math.min(colAmount, maxCollateral); // slice <= lot

            // DAI needed to buy a slice of this sale
            owe = slice * price;

            // Don't collect more than tab of DAI
            if (owe > coinAmount) {
                // Total debt will be paid
                owe = coinAmount; // owe' <= owe
                // Adjust slice
                slice = owe / price; // slice' = owe' / price <= owe / price == slice <= lot
            } else if (owe < coinAmount && slice < colAmount) {
                // If slice == lot => auction completed => dust doesn't matter
                if (coinAmount - owe < minCoin) {
                    // safe as owe < tab
                    // If tab <= chost, buyers have to take the entire lot.
                    require(coinAmount > minCoin, "Clipper/no-partial-purchase");
                    // Adjust amount to pay
                    owe = coinAmount - minCoin; // owe' <= owe
                    // Adjust slice
                    slice = owe / price; // slice' = owe' / price < owe / price == slice < lot
                }
            }

            // Calculate remaining tab after operation
            coinAmount -= owe; // safe since owe <= tab
            // Calculate remaining lot after operation
            colAmount -= slice;

            // Send collateral to who
            cdpEngine.transferCollateral(collateralType, address(this), receiver, slice);

            // Do external call (if data is defined) but to be
            // extremely careful we don't allow to do it to the two
            // contracts which the Clipper needs to be authorized
            if (data.length > 0 && receiver != address(cdpEngine) && receiver != address(liquidationEngine)) {
                ICollateralAuctionCallee(receiver).callback(msg.sender, owe, slice, data);
            }

            // Get DAI from caller
            cdpEngine.transferCoin(msg.sender, dsEngine, owe);

            // Removes Dai out for liquidation from accumulator
            liquidationEngine.removeCoinFromAuction(collateralType, colAmount == 0 ? coinAmount + owe : owe);
        }

        if (colAmount == 0) {
            _remove(id);
        } else if (coinAmount == 0) {
            cdpEngine.transferCollateral(collateralType, address(this), user, colAmount);
            _remove(id);
        } else {
            sales[id].coinAmount = coinAmount;
            sales[id].colAmount = colAmount;
        }
    }

    function _remove(uint256 id) internal {
        uint256 _move = active[active.length - 1];
        if (id != _move) {
            uint256 _index = sales[id].pos;
            active[_index] = _move;
            sales[_move].pos = _index;
        }
        active.pop();
        delete sales[id];
    }

    // Internally returns boolean for if an auction needs a redo
    function status(uint96 startTime, uint256 startPrice) internal view returns (bool done, uint256 price) {
        price = calc.price(startPrice, block.timestamp - startTime);
        done = (block.timestamp - startTime > maxDuration || Math.rdiv(price, startPrice) < minDeltaPriceRatio);
    }

    // Public function to update the cached dust*chop value.
    function updateMinCoin() external {
        ICDPEngine.Collateral memory col = ICDPEngine(cdpEngine).collaterals(collateralType);
        minCoin = Math.wmul(col.minDebt, liquidationEngine.penalty(collateralType));
    }
}

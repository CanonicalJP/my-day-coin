// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {Math} from "../lib/Math.sol";
import {WAD} from "../lib/Math.sol";
import {ICDPEngine} from "../interfaces/ICDPEngine.sol";
import {IGem} from "../interfaces/IGem.sol";
import {IDSEngine} from "../interfaces/IDSEngine.sol";

contract DebtAuction is Auth, CircuitBreaker {
    // --- Data ---
    struct Bid {
        uint256 amount; // dai paid                [rad]
        uint256 lot; // gems in return for bid  [wad]
        address highestBidder; // high bidder
        uint48 bidExpiryTime; // bid expiry time         [unix epoch time]
        uint48 auctionEndTime; // auction expiry time     [unix epoch time]
    }

    mapping(uint => Bid) public bids;

    ICDPEngine public cdpEngine; // CDP Engine
    IGem public gem;

    uint256 public minLotDecrease = 1.05E18; // 5% minimum bid increase
    uint256 public lotIncrease = 1.50E18; // 50% lot increase for tick
    uint48 public bidDuration = 3 hours; // 3 hours bid lifetime         [seconds]
    uint48 public auctionDuration = 2 days; // 2 days total auction length  [seconds]
    uint256 public lastAuctionId = 0;
    address public dsEngine; // not used until shutdown

    // --- Init ---
    constructor(address _cdpEngine, address _gem) {
        cdpEngine = ICDPEngine(_cdpEngine);
        gem = IGem(_gem);
    }

    // --- Auction ---
    function start(address highestBidder, uint lot, uint bidAmount) external auth notStopped returns (uint id) {
        id = ++lastAuctionId;

        bids[id].amount = bidAmount;
        bids[id].lot = lot;
        bids[id].highestBidder = highestBidder;
        bids[id].auctionEndTime = uint48(block.timestamp) + auctionDuration;
    }

    function restart(uint id) external {
        require(bids[id].auctionEndTime < block.timestamp, "Flopper/not-finished");
        require(bids[id].bidExpiryTime == 0, "Flopper/bid-already-placed");
        bids[id].lot = (lotIncrease * bids[id].lot) / WAD;
        bids[id].auctionEndTime = uint48(block.timestamp) + auctionDuration;
    }

    function bid(uint id, uint lot, uint bidAmount) external notStopped {
        require(bids[id].highestBidder != address(0), "Flopper/guy-not-set");
        require(
            bids[id].bidExpiryTime > block.timestamp || bids[id].bidExpiryTime == 0,
            "Flopper/already-finished-tic"
        );
        require(bids[id].auctionEndTime > block.timestamp, "Flopper/already-finished-end");

        require(bidAmount == bids[id].amount, "Flopper/not-matching-bid");
        require(lot < bids[id].lot, "Flopper/lot-not-lower");
        require((minLotDecrease * lot) <= (bids[id].lot * WAD), "Flopper/insufficient-decrease");

        if (msg.sender != bids[id].highestBidder) {
            cdpEngine.transferCoin(msg.sender, bids[id].highestBidder, bidAmount);

            // on first dent, clear as much Ash as possible
            if (bids[id].bidExpiryTime == 0) {
                uint256 debt = IDSEngine(bids[id].highestBidder).totalDebtOnDebtAuction();
                IDSEngine(bids[id].highestBidder).decreaseAuctionDebt(Math.min(bidAmount, debt));
            }

            bids[id].highestBidder = msg.sender;
        }

        bids[id].lot = lot;
        bids[id].bidExpiryTime = uint48(block.timestamp) + bidDuration;
    }

    function claim(uint id) external notStopped {
        require(
            bids[id].bidExpiryTime != 0 &&
                (bids[id].bidExpiryTime < block.timestamp || bids[id].auctionEndTime < block.timestamp),
            "Flopper/not-finished"
        );
        gem.mint(bids[id].highestBidder, bids[id].lot);
        delete bids[id];
    }
}

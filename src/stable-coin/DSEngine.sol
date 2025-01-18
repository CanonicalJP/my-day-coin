// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {Math} from "../lib/Math.sol";
import {ICDPEngine} from "../interfaces/ICDPEngine.sol";
import {IDebtAuction} from "../interfaces/IDebtAuction.sol";
import {ISurplusAuction} from "../interfaces/ISurplusAuction.sol";

// Debt Surplus Engine
contract DSEngine is Auth, CircuitBreaker {
    // --- Data ---
    ICDPEngine public cdpEngine; // CDP Engine
    ISurplusAuction public surplusAuction; // Surplus Auction House
    IDebtAuction public debtAuction; // Debt Auction House

    // timestamp => totalDebt
    mapping(uint256 => uint256) public debtQueue; // debt queue
    uint256 public totalDebtOnQueue; // Queued debt            [rad]
    uint256 public totalDebtOnDebtAuction; // On-auction debt        [rad]

    uint256 public popDebtDelay; // Flop delay             [seconds]
    uint256 public debtAuctionLotSize; // Flop initial lot size  [wad]
    uint256 public debtAuctionBidSize; // Flop fixed bid size    [rad]

    uint256 public surplusAuctionLotSize; // Flap fixed lot size    [rad]
    uint256 public minSurplus; // Surplus buffer         [rad]

    // --- Init ---
    constructor(address _cdpEngine, address _surplusAuction, address _debtAuction) {
        cdpEngine = ICDPEngine(_cdpEngine);
        surplusAuction = ISurplusAuction(_surplusAuction);
        debtAuction = IDebtAuction(_debtAuction);
        cdpEngine.allowAccountModification(_surplusAuction);
    }

    // Push to debt-queue
    // auth: LiquidationEngine
    function pushDebtToQueue(uint debt) external auth {
        debtQueue[block.timestamp] += debt;
        totalDebtOnQueue += debt;
    }

    // Pop from debt-queue
    function popDebtFromQueue(uint time) external {
        require((time + popDebtDelay) <= block.timestamp, "Vow/wait-not-finished");
        totalDebtOnQueue -= debtQueue[time];
        debtQueue[time] = 0;
    }

    // Debt settlement
    function setleDebt(uint rad) external {
        require(rad <= cdpEngine.coin(address(this)), "Vow/insufficient-surplus");
        require(
            rad <= cdpEngine.unbackedDebts(address(this)) - totalDebtOnQueue - totalDebtOnDebtAuction,
            "Vow/insufficient-debt"
        );
        cdpEngine.burn(rad);
    }

    function decreaseAuctionDebt(uint rad) external {
        require(rad <= totalDebtOnDebtAuction, "Vow/not-enough-ash");
        require(rad <= cdpEngine.coin(address(this)), "Vow/insufficient-surplus");
        totalDebtOnDebtAuction -= rad;
        cdpEngine.burn(rad);
    }

    // Debt auction
    function startDebtAuction() external returns (uint id) {
        require(
            (debtAuctionBidSize <= cdpEngine.unbackedDebts(address(this)) - totalDebtOnQueue - totalDebtOnDebtAuction),
            "Vow/insufficient-debt"
        );
        require(cdpEngine.coin(address(this)) == 0, "Vow/surplus-not-zero");
        totalDebtOnDebtAuction += debtAuctionBidSize;
        id = debtAuction.start(address(this), debtAuctionLotSize, debtAuctionBidSize);
    }

    // Surplus auction
    function startSurplusAuction() external returns (uint id) {
        require(
            (cdpEngine.coin(address(this)) >=
                cdpEngine.unbackedDebts(address(this)) + surplusAuctionLotSize + minSurplus),
            "Vow/insufficient-surplus"
        );
        require(
            cdpEngine.unbackedDebts(address(this)) - totalDebtOnQueue - totalDebtOnDebtAuction == 0,
            "Vow/debt-not-zero"
        );
        id = surplusAuction.start(surplusAuctionLotSize, 0);
    }
}

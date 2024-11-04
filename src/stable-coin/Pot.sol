// SPDX-License-Identifier: MIT

// Staking contract for COIN owners
pragma solidity 0.8.24;

import {Auth} from "../lib/Auth.sol";
import {CircuitBreaker} from "../lib/CircuitBreaker.sol";
import {Math} from "../lib/Math.sol";
import {RAY} from "../lib/Math.sol";
import {ICDPEngine} from "../interfaces/ICDPEngine.sol";

/**
 * Pot is the core of the BEI Savings Rate.
 * It allows users to deposit BEI and activate the BEI Savings Rate and
 * earning savings on their BEI. The DSR is set by Maker Governance, and will
 * typically be less than the base stability fee to remain sustainable.
 * The purpose of Pot is to offer another incentive for holding BEI.
 */
contract Pot is Auth, CircuitBreaker {
    // owner => normalized balance of COIN
    mapping(address => uint256) public pie; // Normalised Savings COIN [wad]

    uint256 public totalPie; // Total Normalised Savings Coin  [wad]
    uint256 public savingsRate; // The Coin Savings Rate          [ray]
    uint256 public rateAcc; // The Rate Accumulator          [ray]

    ICDPEngine public cdpEngine; // CDP Engine
    address public dsEngine; // Debt Engine
    uint256 public updatedAt; // Time of last drip     [unix epoch time]

    constructor(address _cdpEngine) {
        cdpEngine = ICDPEngine(_cdpEngine);
        savingsRate = RAY;
        rateAcc = RAY;
        updatedAt = block.timestamp;
    }

    ///// PROTOCOL MANAGEMENT /////

    /**
     * @notice stop (a.k.a pause) contract
     */
    function stop() external auth {
        _stop();
        savingsRate = RAY;
    }

    /**
     * @notice change the value of the savingsRate
     * @param _key state variable to update
     * @param _value new value of state variable
     */
    function set(bytes32 _key, uint256 _value) external auth notStopped {
        require(block.timestamp == updatedAt, "Pot: updateAt has to be now"); // this function has to be called along with collectStabilityFee
        if (_key == "savingsRate") savingsRate = _value;
        else revert("Pot: _key not recognized");
    }

    /**
     * @notice change the address of the dsEngine
     * @param _key state variable to update
     * @param _addr new dsEngine
     */
    function set(bytes32 _key, address _addr) external auth {
        if (_key == "dsEngine") dsEngine = _addr;
        else revert("Pot: _key not recognized");
    }

    ///// USER FACING ////

    // --- Savings Rate Accumulation ---
    /**
     * @notice Update the Rate Accumulator
     */
    function collectStabilityFee() external returns (uint256 newRateAcc) {
        require(block.timestamp >= updatedAt, "Pot: now cannot be less than updatedAt");
        newRateAcc = Math.rmul(Math.rpow(savingsRate, block.timestamp - updatedAt, RAY), rateAcc);
        uint256 deltaRateAcc = newRateAcc - rateAcc;
        rateAcc = newRateAcc;
        updatedAt = block.timestamp;
        // old total COIN = totalPie * old rateAcc
        // new total COIN = totalPie * new rateAcc
        // amount of COIN to mint = totalPie * (new rateAcc - old rateAcc)
        cdpEngine.mint(address(dsEngine), address(this), totalPie * deltaRateAcc);
    }

    // --- Savings Coin Management ---
    /**
     * @notice user deposits COIN
     * @param wad COIN to deposit
     */
    function join(uint wad) external {
        require(block.timestamp == updatedAt, "Pot: updateAt has to be now"); // this function has to be called along with collectStabilityFee
        pie[msg.sender] += wad;
        totalPie += wad;
        cdpEngine.transferCoin(msg.sender, address(this), rateAcc * wad);
    }

    /**
     * @notice user withdraws COIN
     * @param wad COIN to withdraw
     */
    function exit(uint wad) external {
        pie[msg.sender] -= wad;
        totalPie -= wad;
        cdpEngine.transferCoin(address(this), msg.sender, rateAcc * wad);
    }
}

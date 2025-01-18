// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface ISurplusAuction {
    function start(uint256, uint256) external returns (uint256);
}

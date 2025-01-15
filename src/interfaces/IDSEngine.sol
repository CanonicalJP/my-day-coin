// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IDSEngine {
    function pushDebtToQueue(uint256) external;
}

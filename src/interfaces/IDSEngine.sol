// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface IDSEngine {
    function pushDebtToQueue(uint256) external;

    function totalDebtOnDebtAuction() external view returns (uint256);

    function decreaseAuctionDebt(uint256) external;
}

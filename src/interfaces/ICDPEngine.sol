// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface ICDPEngine {
    function modifyCollateralBalance(bytes32, address, int) external;

    function transferCoin(address, address, uint) external;
}

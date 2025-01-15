// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface ICollateralAuction {
    function collateralType() external view returns (bytes32);

    function start(uint256, uint256, address, address) external returns (uint256);
}

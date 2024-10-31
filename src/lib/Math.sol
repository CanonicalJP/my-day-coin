// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

uint256 constant WAD = 10 ** 18;
uint256 constant RAY = 10 ** 27;
uint256 constant RAD = 10 ** 45;

library Math {
    // --- Math ---

    function add(uint x, int y) external pure returns (uint z) {
        // z = x + uint(y);
        // require(y >= 0 || z <= x);
        // require(y <= 0 || z >= x);
        return y >= 0 ? x + uint(y) : x - uint(-y);
    }
}
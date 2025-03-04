// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

abstract contract Guard {
    uint256 private locked;

    modifier lock() {
        require(locked == 0, "locked");
        locked = 1;
        _;
        locked = 0;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

abstract contract Auth {
    // Events
    event GrantAuthorization(address indexed usr);
    event DenyAuthorization(address indexed usr);

    // --- Auth ---
    mapping(address => bool) public authorized;

    modifier auth() {
        require(authorized[msg.sender], "Noth Authorized");
        _;
    }

    constructor() {
        authorized[msg.sender] = true;
        emit GrantAuthorization(msg.sender);
    }

    function grantAuth(address usr) external auth {
        authorized[usr] = true;
        emit GrantAuthorization(usr);
    }

    function denyAuth(address usr) external auth {
        authorized[usr] = false;
        emit DenyAuthorization(usr);
    }
}

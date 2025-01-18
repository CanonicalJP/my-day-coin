// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

interface ICDPEngine {
    struct Collateral {
        uint256 debt; // Total Normalised Debt, the amount borrowed / rate accumulation at the time of borrowing     [wad]
        uint256 rateAcc; // Accumulated Rates         [ray]
        uint256 spot; // Price with Safety Margin  [ray]
        uint256 maxDebt; // Debt Ceiling              [rad]
        uint256 minDebt; // Urn Debt Floor            [rad]
    }
    struct Position {
        uint256 collateral; // Locked Collateral  [wad]
        uint256 debt; // Total Normalised Debt, the amount borrowed / rate accumulation at the time of borrowing     [wad]
    }

    function modifyCollateralBalance(bytes32, address, int) external;

    function transferCollateral(bytes32, address, address, uint256) external;

    function transferCoin(address, address, uint) external;

    function set(bytes32, bytes32, uint) external;

    function collaterals(bytes32) external view returns (Collateral memory);

    function allowAccountModification(address) external;

    function burn(uint256) external;

    function mint(address, address, uint256) external;

    function updateRateAcc(bytes32, address, int256) external;

    function grab(bytes32, address, address, address, int256, int256) external;

    ///// GETTERS /////

    function positions(bytes32, address) external view returns (Position memory);

    function gem(bytes32, address) external view returns (uint256);

    function coin(address) external view returns (uint256);

    function unbackedDebts(address) external view returns (uint256);

    function sysDebt() external view returns (uint256);

    function sysUnbackedDebt() external view returns (uint256);

    function sysMaxDebt() external view returns (uint256);
}

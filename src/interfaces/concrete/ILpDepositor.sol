// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface ILpDepositor {
    function setTokenID(uint256 tokenID) external returns (bool);
    function userBalances(address user, address pool) external view returns (uint256);
    function totalBalances(address pool) external view returns (uint256);
    function transferDeposit(address pool, address from, address to, uint256 amount) external returns (bool);
    function whitelist(address token) external returns (bool);
}
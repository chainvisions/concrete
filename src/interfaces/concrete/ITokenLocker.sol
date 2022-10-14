// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface ITokenLocker {
    function getWeek() external view returns (uint256);
    function weeklyWeight(address user, uint256 week) external view returns (uint256, uint256);
    function userWeight(address _user) external view returns (uint256);
    function startTime() external view returns (uint256);
}
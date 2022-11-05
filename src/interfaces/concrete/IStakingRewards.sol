// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStakingRewards {
    function stake(uint256) external;
    function withdraw(uint256) external;
    function getReward() external;
    function exit() external;
    function balanceOf(address) external view returns (uint256);
}
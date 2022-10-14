// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IGauge {
    function deposit(uint amount, uint tokenId) external;
    function withdraw(uint amount) external;
    function getReward(address account, address[] memory tokens) external;
    function earned(address token, address account) external view returns (uint256);
}
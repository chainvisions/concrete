// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IBribe {
    function getReward(uint tokenId, address[] memory tokens) external;
}
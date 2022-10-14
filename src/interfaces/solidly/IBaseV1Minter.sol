// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IBaseV1Minter {
    function active_period() external view returns (uint256);
}
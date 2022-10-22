// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IMigrateable {
    function migrate(address _to) external;
    function governance() external view returns (address);
}
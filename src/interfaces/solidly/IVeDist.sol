// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IVeDist {
    function claim(uint _tokenId) external returns (uint);
}
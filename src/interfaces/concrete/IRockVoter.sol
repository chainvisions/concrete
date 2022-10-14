// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IRockVoter {
    function setTokenID(uint256 tokenID) external returns (bool);
}
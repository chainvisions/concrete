// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../IERC20.sol";

interface IVeDepositor is IERC20 {
    function depositTokens(uint256 amount) external returns (bool);
}
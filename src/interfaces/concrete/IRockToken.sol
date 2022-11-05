// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../IERC20.sol";

interface IRockToken is IERC20 {
    function mint(address _to, uint256 _value) external returns (bool);
    function rebase(address _pair, uint256 _offset) external;
}
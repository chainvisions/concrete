// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IFeeDistributor {
    function depositFee(address _token, uint256 _amount) external returns (bool);
}
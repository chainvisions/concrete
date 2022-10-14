// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IRockPartners {
    function earlyPartnerPct() external view returns (uint256);
    function isEarlyPartner(address account) external view returns (bool);
}
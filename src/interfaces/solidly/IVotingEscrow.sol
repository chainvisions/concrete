// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IVotingEscrow {
    function increase_amount(uint256 tokenID, uint256 value) external;
    function increase_unlock_time(uint256 tokenID, uint256 duration) external;
    function split(uint256 _from, uint256 _amount) external returns (uint256);
    function merge(uint256 fromID, uint256 toID) external;
    function locked(uint256 tokenID) external view returns (uint256 amount, uint256 unlockTime);
    function attach(uint256 _tokenId) external;
    function detach(uint256 _tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function transferFrom(address from, address to, uint256 tokenID) external;
    function safeTransferFrom(address from, address to, uint tokenId) external;
    function ownerOf(uint tokenId) external view returns (address);
    function balanceOfNFT(uint tokenId) external view returns (uint);
    function isApprovedOrOwner(address, uint) external view returns (bool);
    function attachments(uint256) external view returns (uint256);
}
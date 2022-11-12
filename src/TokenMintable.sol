// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.13;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mintable ERC20 Token
/// @author Chainvisions
/// @notice Contract for mintable ERC20 tokens.

contract TokenMintable is ERC20 {

    /// @notice Owner of the token.
    address public owner;

    /// @notice Constructor for the token.
    /// @param _name Name of the token.
    /// @param _symbol Symbol of the token.
    constructor(
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        owner = msg.sender;
    }

    /// @notice Mints tokens to an address.
    /// @param _to Address to mint tokens to.
    /// @param _amount Amount of tokens to mint.
    function mint(address _to, uint256 _amount) external {
        require(msg.sender == owner, "Not owner");
        _mint(_to, _amount);
    }

    /// @notice Burns tokens.
    /// @param _amount Amount of tokens to burn.
    function burn(uint256 _amount) external {
        _burn(msg.sender, _amount);
    }
}
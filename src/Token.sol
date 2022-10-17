// SPDX-License-Identifier: MIT 
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ROCK Token
/// @author Chainvisions
/// @notice Contract for the ROCK token.

contract RockToken is ERC20("Concrete Finance", "ROCK"), Ownable {

    mapping(address => bool) public minters;

    /**
        @notice Approve contracts to mint and renounce ownership
        @dev In production the only minters should be `LpDepositor` and `RockPartners`
             Addresses are given via dynamic array to allow extra minters during testing
     */
    function setMinters(address[] calldata _minters) external onlyOwner {
        for (uint256 i; i < _minters.length;) {
            minters[_minters[i]] = true;
            unchecked { ++i; }
        }

        renounceOwnership();
    }

    function mint(address _to, uint256 _value) external returns (bool) {
        require(minters[msg.sender], "Not a minter");
        _mint(_to, _value);
        return true;
    }

}
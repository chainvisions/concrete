// SPDX-License-Identifier: MIT 
pragma solidity 0.8.16;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IVotingEscrow} from "./interfaces/solidly/IVotingEscrow.sol";
import {IVeDist} from "./interfaces/solidly/IVeDist.sol";
import {ILpDepositor} from "./interfaces/concrete/ILpDepositor.sol";
import {IFeeDistributor} from "./interfaces/concrete/IFeeDistributor.sol";
import {IRockVoter} from "./interfaces/concrete/IRockVoter.sol";

/// @title Concrete VeDepositor
/// @author Chainvisions, forked from Solidex
/// @notice Contract for converting veSOLID into rockSOLID.

contract VeDepositor is ERC20("rockSOLID: Tokenized veSOLID", "rockSOLID"), Ownable {
    // Solidly contracts
    IERC20 public immutable token;
    IVotingEscrow public immutable votingEscrow;
    IVeDist public immutable veDistributor;

    // Concrete contracts
    ILpDepositor public lpDepositor;
    IRockVoter public rockVoter;
    IFeeDistributor public feeDistributor;

    uint256 public tokenID;
    uint256 public unlockTime;

    uint256 constant MAX_LOCK_TIME = 86400 * 365 * 4;
    uint256 constant WEEK = 86400 * 7;

    event ClaimedFromVeDistributor(address indexed user, uint256 amount);
    event Merged(address indexed user, uint256 tokenID, uint256 amount);
    event UnlockTimeUpdated(uint256 unlockTime);

    constructor(
        IERC20 _token,
        IVotingEscrow _votingEscrow,
        IVeDist _veDist
    ) {
        token = _token;
        votingEscrow = _votingEscrow;
        veDistributor = _veDist;

        // approve vesting escrow to transfer SOLID (for adding to lock)
        _token.approve(address(_votingEscrow), type(uint256).max);
    }

    /// @notice Burns rockSOLID tokens from a specified address.
    /// @param account The address to burn tokens from.
    /// @param amount The amount of tokens to burn.
    function burnFrom(address account, uint256 amount) external {
        require(msg.sender == address(lpDepositor), "Only LpDepositor");
        _burn(account, amount);
    }

    function setAddresses(
        ILpDepositor _lpDepositor,
        IRockVoter _rockVoter,
        IFeeDistributor _feeDistributor
    ) external onlyOwner {
        lpDepositor = _lpDepositor;
        rockVoter = _rockVoter;
        feeDistributor = _feeDistributor;

        // approve fee distributor to transfer this token (for distributing rockSOLID)
        _approve(address(this), address(_feeDistributor), type(uint256).max);
        renounceOwnership();
    }

    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenID,
        bytes calldata
    ) external returns (bytes4) {
        _from;
        require(msg.sender == address(votingEscrow), "Can only receive veSOLID NFTs");
        (uint256 amount, uint256 end) = votingEscrow.locked(_tokenID);

        if (tokenID == 0) {
            tokenID = _tokenID;
            unlockTime = end;
            rockVoter.setTokenID(tokenID);
            votingEscrow.safeTransferFrom(address(this), address(lpDepositor), _tokenID);
        } else {
            votingEscrow.merge(_tokenID, tokenID);
            if (end > unlockTime) unlockTime = end;
            emit Merged(_operator, _tokenID, amount);
        }

        _mint(_operator, amount);
        extendLockTime();

        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }

    /**
        @notice Merge a veSOLID NFT previously sent to this contract
                with the main Concrete NFT
        @dev This is primarily meant to allow claiming balances from NFTs
             incorrectly sent using `transferFrom`. To deposit an NFT
             you should always use `safeTransferFrom`.
        @param _tokenID ID of the NFT to merge
        @return bool success
     */
    function merge(uint256 _tokenID) external returns (bool) {
        require(tokenID != _tokenID);
        (uint256 amount, uint256 end) = votingEscrow.locked(_tokenID);
        require(amount > 0);

        votingEscrow.merge(_tokenID, tokenID);
        if (end > unlockTime) unlockTime = end;
        emit Merged(msg.sender, _tokenID, amount);

        _mint(msg.sender, amount);
        extendLockTime();

        return true;
    }

    /**
        @notice Deposit SOLID tokens and mint rockSOLID
        @param _amount Amount of SOLID to deposit
        @return bool success
     */
    function depositTokens(uint256 _amount) external returns (bool) {
        require(tokenID != 0, "First deposit must be NFT");

        token.transferFrom(msg.sender, address(this), _amount);
        votingEscrow.increase_amount(tokenID, _amount);
        _mint(msg.sender, _amount);
        extendLockTime();

        return true;
    }

    /**
        @notice Extend the lock time of the protocol's veSOLID NFT
        @dev Lock times are also extended each time new rockSOLID is minted.
             If the lock time is already at the maximum duration, calling
             this function does nothing.
     */
    function extendLockTime() public {
        uint256 maxUnlock = ((block.timestamp + MAX_LOCK_TIME) / WEEK) * WEEK;
        if (maxUnlock > unlockTime) {
            votingEscrow.increase_unlock_time(tokenID, MAX_LOCK_TIME);
            unlockTime = maxUnlock;
            emit UnlockTimeUpdated(unlockTime);
        }
    }

    /**
        @notice Claim veSOLID received via ve(3,3)
        @dev This function is unguarded, anyone can call to claim at any time.
             The new veSOLID is represented by newly minted rockSOLID, which is
             then sent to `FeeDistributor` and streamed to ROCK lockers starting
             at the beginning of the following epoch week.
     */
    function claimFromVeDistributor() external returns (bool) {
        veDistributor.claim(tokenID);

        // calculate the amount by comparing the change in the locked balance
        // to the known total supply, this is necessary because anyone can call
        // `veDistributor.claim` for any NFT
        (uint256 amount,) = votingEscrow.locked(tokenID);
        amount -= totalSupply();

        if (amount > 0) {
            _mint(address(this), amount);
            feeDistributor.depositFee(address(this), balanceOf(address(this)));
            emit ClaimedFromVeDistributor(address(this), amount);
        }

        return true;
    }
}
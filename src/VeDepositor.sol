// SPDX-License-Identifier: MIT 
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IVotingEscrow} from "./interfaces/solidly/IVotingEscrow.sol";
import {IVeDist} from "./interfaces/solidly/IVeDist.sol";
import {ILpDepositor} from "./interfaces/concrete/ILpDepositor.sol";
import {IFeeDistributor} from "./interfaces/concrete/IFeeDistributor.sol";
import {IRockVoter} from "./interfaces/concrete/IRockVoter.sol";
import {TokenMintable} from "./TokenMintable.sol";

/// @title Concrete VeDepositor
/// @author Chainvisions, forked from Solidex
/// @notice Contract for converting veSOLID into rockSOLID.

contract VeDepositor is ERC20("rockSOLID: Tokenized veSOLID", "rockSOLID"), Ownable {

    /// @notice Solidly SOLID token.
    IERC20 public immutable token;

    /// @notice Receipt token for splitting.
    IERC20 public immutable splitReceipt;

    /// @notice Solidly voting escrow.
    IVotingEscrow public immutable votingEscrow;

    /// @notice Solidly veSOLID distribution contract.
    IVeDist public immutable veDistributor;

    /// @notice Concrete LP Depositor contract.
    ILpDepositor public lpDepositor;

    /// @notice Concrete voting contract.
    IRockVoter public rockVoter;

    /// @notice Concrete fee distributor contract.
    IFeeDistributor public feeDistributor;

    /// @notice veNFT ID.
    uint256 public tokenID;

    /// @notice veNFT redeemable for splitting.
    uint256 public redeemableTokenID;

    /// @notice Unlock time of the veNFT.
    uint256 public unlockTime;

    /// @notice Total amount of gauge attachments.
    uint256 public totalAttachments;

    /// @notice Amount of veSOLID supply to split.
    uint256 public totalSupplyToSplit;

    /// @notice Current split worker.
    address public worker;

    /// @notice Time of last work start.
    uint256 public workTime;

    /// @notice rockSOLID reward for splitting.
    uint256 public splitReward;

    /// @notice Current bounty for a successful split.
    uint256 public totalBondBounty;

    /// @notice Last time a split was completed.
    uint256 public lastSplit;

    bool private addressesSet;
    bool private hasSplit;

    uint256 constant MAX_LOCK_TIME = 86400 * 365 * 4;
    uint256 constant WEEK = 86400 * 7;
    uint256 constant MAX_WORK_LAG = 2 hours;

    /// @notice Emitted when tokens are claimed from the veNFT.
    /// @param user Address of the user who claimed.
    /// @param amount Amount of tokens claimed.
    event ClaimedFromVeDistributor(address indexed user, uint256 amount);

    /// @notice Emitted when the veNFT is merged.
    /// @param user Address of the user who deposited the veNFT.
    /// @param tokenID ID of the veNFT.
    /// @param amount Amount of tokens in the veNFT.
    event Merged(address indexed user, uint256 tokenID, uint256 amount);

    /// @notice Emitted when the veNFT unlock time is extended.
    /// @param unlockTime New unlock time.
    event UnlockTimeUpdated(uint256 unlockTime);

    /// @notice Constructor for the VeDepositor contract.
    /// @param _token SOLID token.
    /// @param _votingEscrow Solidly voting escrow.
    /// @param _veDist Solidly veSOLID distribution contract.
    constructor(
        IERC20 _token,
        IVotingEscrow _votingEscrow,
        IVeDist _veDist
    ) {
        token = _token;
        splitReceipt = IERC20(address(new TokenMintable("Concrete Split Receipt", "rSPLIT")));
        votingEscrow = _votingEscrow;
        veDistributor = _veDist;

        // approve vesting escrow to transfer SOLID (for adding to lock)
        _token.approve(address(_votingEscrow), type(uint256).max);
    }

    /// @notice Sets Concrete addresses.
    /// @param _lpDepositor Concrete LP Depositor contract.
    /// @param _rockVoter Concrete voting contract.
    /// @param _feeDistributor Concrete fee distributor contract.
    function setAddresses(
        ILpDepositor _lpDepositor,
        IRockVoter _rockVoter,
        IFeeDistributor _feeDistributor
    ) external onlyOwner {
        require(!addressesSet, "Addresses already set");
        lpDepositor = _lpDepositor;
        rockVoter = _rockVoter;
        feeDistributor = _feeDistributor;

        // approve fee distributor to transfer this token (for distributing rockSOLID)
        _approve(address(this), address(_feeDistributor), type(uint256).max);
        addressesSet = true;
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

    /// @notice Merges a veNFT with the main veNFT.
    /// @param _tokenID ID of the veNFT to merge.
    /// @return bool success.
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

    /// @notice Splits the veNFT into two NFTs.
    /// @param _amount Amount of rockSOLID to burn to create the new NFT.
    function split(uint256 _amount) external returns (bool) {
        require(_amount > 0);

        // Handle MEV rewards for detatching gauges.
        uint256 keeperFee = (_amount * 50) / 10000;
        uint256 postFee = _amount - keeperFee;
        splitReward += keeperFee;

        // Burn rockSOLID and mint receipt token.
        _transfer(msg.sender, address(this), keeperFee);
        _burn(msg.sender, postFee);
        totalSupplyToSplit += postFee;
        TokenMintable(address(splitReceipt)).mint(msg.sender, postFee);
        return true;
    }

    /// @notice Redeems a split receipt for a new veNFT.
    /// @param _amount Amount of receipt tokens to burn to create the new NFT.
    function redeemSplitReceipt(
        uint256 _amount
    ) external returns (bool, uint256) {
        require(_amount > 0, "Amount must be greater than 0");
        uint256 _redeemableTokenID = redeemableTokenID;

        // Burn receipt tokens.
        votingEscrow.increase_unlock_time(_redeemableTokenID, MAX_LOCK_TIME);
        splitReceipt.transferFrom(msg.sender, address(this), _amount);
        TokenMintable(address(splitReceipt)).burn(_amount);

        // Perform the split.
        uint256 newID = votingEscrow.split(_redeemableTokenID, _amount);
        votingEscrow.safeTransferFrom(address(this), msg.sender, newID);
        
        return (true, newID);
    }

    /// @notice Deposits SOLID tokens and mints rockSOLID.
    /// @param _amount Amount of SOLID to deposit.
    /// @return bool success.
    function depositTokens(uint256 _amount) external returns (bool) {
        require(tokenID != 0, "First deposit must be NFT");

        token.transferFrom(msg.sender, address(this), _amount);
        votingEscrow.increase_amount(tokenID, _amount);
        _mint(msg.sender, _amount);
        extendLockTime();

        return true;
    }

    /// @notice Extend the lock time of the protocol's veSOLID NFT.
    function extendLockTime() public {
        uint256 maxUnlock = ((block.timestamp + MAX_LOCK_TIME) / WEEK) * WEEK;
        if (maxUnlock > unlockTime) {
            votingEscrow.increase_unlock_time(tokenID, MAX_LOCK_TIME);
            unlockTime = maxUnlock;
            emit UnlockTimeUpdated(unlockTime);
        }
    }

    /// @notice Claim veSOLID received via ve(3,3).
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

    /// @notice Skims held ether generated from MEV capture.
    function skim() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    /// @notice Starts work on splitting the veNFT.
    function startWork() external payable {
        require(msg.value >= 0.1 ether);
        require(block.timestamp >= lastSplit + WEEK, "Weekly split has already been complete");
        uint256 _workTime = workTime;

        // Update attachments.
        uint256 currentVeAttachments = votingEscrow.attachments(tokenID);
        if (currentVeAttachments > totalAttachments) totalAttachments = currentVeAttachments;

        // Grant worker permissions if it has been 2h since the last work.
        if(block.timestamp >= _workTime + MAX_WORK_LAG) {
            worker = msg.sender;
            workTime = block.timestamp;
        } else if(msg.value > totalBondBounty) {
            // Allow for the worker role to be taken if the bond offered is higher.
            worker = msg.sender;
        }

        // Update the total bond bounty.
        totalBondBounty += msg.value - ((msg.value * 100) / 10000);
    }

    /// @notice Detaches gauges from the protocol's veNFT.
    function detachGauges(address[] calldata _gauges) external {
        require(msg.sender == worker, "Only the worker can detach gauges");
        require(block.timestamp < workTime + MAX_WORK_LAG, "Work has expired");

        // Detach gauges.
        uint256 _tokenID = tokenID;
        for(uint256 i; i < _gauges.length;) {
            // Needs to support latest Solidly interface.
            votingEscrow.detach(_tokenID);
            unchecked { ++i; }
        }
    }

    /// @notice Attaches gauges from the protocol's veNFT.
    function attachGauges(address[] calldata _gauges) external {
        require(msg.sender == worker, "Only the worker can attach gauges");
        require(block.timestamp < workTime + MAX_WORK_LAG, "Work has expired");

        // Attach gauges.
        uint256 _tokenID = tokenID;
        for(uint256 i; i < _gauges.length;) {
            // Needs to support latest Solidly interface.
            votingEscrow.attach(_tokenID);
            unchecked { ++i; }
        }
    }

    /// @notice Completes work on splitting the veNFT.
    function performSplit() external {
        require(msg.sender == worker, "Only the worker can carry out splitting");
        require(block.timestamp < workTime + MAX_WORK_LAG, "Work has expired");
        require(!hasSplit, "Already split");

        // If there is remaining SOLID in the last split NFT, merge it into the main NFT.
        uint256 _tokenID = tokenID;
        uint256 _redeemableTokenID = redeemableTokenID;
        (uint256 amount,) = votingEscrow.locked(_redeemableTokenID);
        if(amount > 0) {
            votingEscrow.increase_unlock_time(_redeemableTokenID, MAX_LOCK_TIME);
            votingEscrow.merge(_redeemableTokenID, _tokenID);
        }

        // Split the main NFT.
        redeemableTokenID = votingEscrow.split(_tokenID, totalSupplyToSplit);
        totalSupplyToSplit = 0;
        hasSplit = true;
    }

    /// @notice Claims reward for splitting the veNFT.
    function claimWork() external {
        require(msg.sender == worker, "Only the worker can claim work");
        require(block.timestamp < workTime + MAX_WORK_LAG, "Work has expired");
        require(votingEscrow.attachments(tokenID) == totalAttachments, "Work has not been completed");

        // Set workers to 0.
        worker = address(0);
        workTime = 0;
        hasSplit = false;
        lastSplit = block.timestamp;

        // Transfer the bounty to the worker.
        _transfer(address(this), msg.sender, splitReward);
        payable(msg.sender).transfer(totalBondBounty);
    }
}
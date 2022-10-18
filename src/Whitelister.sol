// SPDX-License-Identifier: MIT 
pragma solidity 0.8.16;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ILpDepositor} from "./interfaces/concrete/ILpDepositor.sol";
import {IRockPartners} from "./interfaces/concrete/IRockPartners.sol";
import {IBaseV1Voter} from "./interfaces/solidly/IBaseV1Voter.sol";
import {IVeDepositor} from "./interfaces/concrete/IVeDepositor.sol";
import {IFeeDistributor} from "./interfaces/concrete/IFeeDistributor.sol";

contract Whitelister is ERC20("Concrete Whitelisting Token", "ROCK-WL"), Ownable {
    mapping(address => uint256) public lastEarlyPartnerMint;

    IERC20 public immutable SOLID;
    IBaseV1Voter public immutable solidlyVoter;

    ILpDepositor public lpDepositor;
    IRockPartners public rockPartners;
    IVeDepositor public rockSOLID;
    IFeeDistributor public feeDistributor;

    uint256 public biddingPeriodEnd;
    uint256 public highestBid;
    address public highestBidder;

    event HigestBid(address indexed user, uint256 amount);
    event NewBiddingPeriod(uint256 indexed end);
    event Whitelisted(address indexed token);

    constructor(IERC20 _solid, IBaseV1Voter _solidlyVoter) {
        SOLID = _solid;
        solidlyVoter = _solidlyVoter;
        emit Transfer(address(0), msg.sender, 0);
    }

    function setAddresses(
        ILpDepositor _lpDepositor,
        IRockPartners _partners,
        IVeDepositor _rockSolid,
        IFeeDistributor _distributor
    ) external onlyOwner {
        lpDepositor = _lpDepositor;
        rockPartners = _partners;
        rockSOLID = _rockSolid;
        feeDistributor = _distributor;

        SOLID.approve(address(_rockSolid), type(uint256).max);
        rockSOLID.approve(address(_distributor), type(uint256).max);

        renounceOwnership();
    }

    /**
        @notice Mint three free whitelist tokens as an early partner
        @dev Each early partner may call this once every 30 days
     */
    function earlyPartnerMint() external {
        require(rockPartners.isEarlyPartner(msg.sender), "Not an early partner");
        require(lastEarlyPartnerMint[msg.sender] + 86400 * 30 < block.timestamp, "One mint per month");

        lastEarlyPartnerMint[msg.sender] = block.timestamp;
        _mint(msg.sender, 3e18);
    }

    function isActiveBiddingPeriod() public view returns (bool) {
        return biddingPeriodEnd >= block.timestamp;
    }

    function canClaimFinishedBid() public view returns (bool) {
        return biddingPeriodEnd > 0 && biddingPeriodEnd < block.timestamp;
    }

    function minimumBid() public view returns (uint256) {
        if (isActiveBiddingPeriod()) {
            return highestBid * 101 / 100;
        }
        uint256 fee = solidlyVoter.listing_fee();
        // quote 0.1% higher as ve expansion between quote time and submit time can change listing_fee
        return fee / 10 + (fee / 1000);
    }

    function _minimumBid() internal view returns (uint256) {
        if (isActiveBiddingPeriod()) {
            return highestBid * 101 / 100;
        }
        return solidlyVoter.listing_fee() / 10;
    }

    /**
        @notice Bid to purchase a whitelist token with SOLID
        @dev Each bidding period lasts for three days. The initial bid must be
             at least 10% of the current solidly listing fee. Subsequent bids
             must increase the bid by at least 1%. The full SOLID amount is
             transferred from the bidder during the call, and the amount taken
             from the previous bidder is refunded.
        @param amount Amount of SOLID to bid
     */
    function bid(uint256 amount) external {
        require(amount >= _minimumBid(), "Below minimum bid");

        if (canClaimFinishedBid()) {
            // if the winning bid from the previous period was not claimed,
            // execute it prior to starting a new period
            claimFinishedBid();
        } else if (highestBid != 0) {
            // if there is already a previous bid, return it to the bidder
            SOLID.transfer(highestBidder, highestBid);
        }

        if (biddingPeriodEnd == 0) {
            // if this is the start of a new period, set the end as +3 days
            biddingPeriodEnd = block.timestamp + 86400 * 3;
            emit NewBiddingPeriod(biddingPeriodEnd);
        }

        // transfer SOLID from the caller and record them as the highest bidder
        SOLID.transferFrom(msg.sender, address(this), amount);
        highestBid = amount;
        highestBidder = msg.sender;
        emit HigestBid(msg.sender, amount);
    }

    /**
        @notice Mint a new whitelist token for the highest bidder in the finished period
        @dev Placing a bid to start a new period will also triggers a claim
     */
    function claimFinishedBid() public {
        require(biddingPeriodEnd > 0 && biddingPeriodEnd < block.timestamp, "No pending claim");

        rockSOLID.depositTokens(highestBid);
        feeDistributor.depositFee(address(rockSOLID), highestBid);

        _mint(highestBidder, 1e18);

        highestBid = 0;
        highestBidder = address(0);
        biddingPeriodEnd = 0;
    }

    /**
        @notice Whitelist a new token in Solidly
        @dev This function burns 1 whitelist token from the caller's balance
        @param token Address of the token to whitelist
     */
    function whitelist(address token) external {
        require(balanceOf(msg.sender) >= 1e18, "Insufficient balance");
        _burn(msg.sender, 1e18);
        lpDepositor.whitelist(token);
        emit Whitelisted(token);
    }

}
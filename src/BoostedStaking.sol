// SPDX-License-Identifier: MIT 
pragma solidity 0.8.13;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeTransferLib} from "./lib/SafeTransferLib.sol";

/// @title Boosted Staking
/// @author Chainvisions, forked from Solidex
/// @notice Boosted StakingRewards contract for staking rockSOLID.

contract BoostedStaking is Ownable {
    using SafeTransferLib for IERC20;

    /// @notice Reward data for each reward token.
    struct Reward {
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        uint256 balance;
    }

    /// @notice Reward data for boost tokens.
    struct Points {
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }

    /// @notice Duration for reward distribution.
    uint256 public constant REWARDS_DURATION = 86400 * 7;

    /// @notice Staking token of the contract.
    IERC20 public stakingToken;

    /// @notice Reward tokens distributed by the contract.
    address[2] public rewardTokens;

    /// @notice Total staked amount.
    uint256 public totalSupply;

    /// @notice Total boosted supply.
    uint256 public derivedSupply;

    /// @notice Total amount of boost tokens.
    uint256 public boostPointSupply;

    /// @notice Amount of boost tokens distributed per second.
    uint256 public boostRate;

    /// @notice Boost token reward accounting.
    Points public boostAccounting;

    /// @notice Data for each reward token.
    mapping(address => Reward) public rewardData;

    /// @notice Paid out rewards to a user per staked token.
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;

    /// @notice Pending rewards for a user.
    mapping(address => mapping(address => uint256)) public rewards;

    /// @notice User's staked amount.
    mapping(address => uint256) public balanceOf;

    /// @notice User's balance of boost tokens.
    mapping(address => uint256) public boostBalance;

    /// @notice User's derived balance.
    mapping(address => uint256) public derivedBalances;

    /// @notice Boost point rewards for a user.
    mapping(address => uint256) public pointRewards;

    /// @notice Paid out points to a user per staked token.
    mapping(address => uint256) public userPointsPerTokenPaid;

    /// @notice Emitted when rewards are added to the contract.
    /// @param rewardsToken Address of the reward token.
    /// @param reward Amount of reward tokens added.
    event RewardAdded(address indexed rewardsToken, uint256 reward);

    /// @notice Emitted when a user stakes tokens into the contract.
    /// @param user Address of the user.
    /// @param amount Amount of tokens staked.
    event Staked(address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws tokens from the contract.
    /// @param user Address of the user.
    /// @param amount Amount of tokens withdrawn.
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when a user claims rewards from the contract.
    /// @param user Address of the user.
    /// @param rewardsToken Reward token claimed.
    /// @param reward Amount of rewards claimed.
    event RewardPaid(address indexed user, address indexed rewardsToken, uint256 reward);

    /// @notice Emitted when points are paid out to a user.
    /// @param user Address of the user.
    /// @param points Amount of points paid out.
    event PointsPaid(address indexed user, uint256 points);

    /// @notice Emitted when the rate of boost points is changed.
    /// @param newRate New rate of boost points.
    event RateAdjusted(uint256 newRate);

    /// @notice Sets addresses for the staking contract.
    /// @param _stakingToken The address of the staking token.
    /// @param _rewardTokens The addresses of the reward tokens.
    function setAddresses(
        address _stakingToken,
        address[2] memory _rewardTokens
    ) external onlyOwner {
        stakingToken = IERC20(_stakingToken);  // rockSOLID
        rewardTokens = _rewardTokens;  // SOLID, ROCK
        renounceOwnership();
    }

    function lastTimeRewardApplicable(address _rewardsToken) public view returns (uint256) {
        uint256 periodFinish = rewardData[_rewardsToken].periodFinish;
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken(address _rewardsToken) public view returns (uint256) {
        Reward memory data = rewardData[_rewardsToken];
        if (totalSupply == 0) {
            return data.rewardPerTokenStored;
        }
        uint256 duration = lastTimeRewardApplicable(_rewardsToken) - data.lastUpdateTime;
        uint256 pending = duration * data.rewardRate * 1e18 / derivedSupply;
        return
            data.rewardPerTokenStored + pending;
    }

    function pointsPerToken() public view returns (uint256) {
        Points memory data = boostAccounting;
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            return data.rewardPerTokenStored;
        }
        uint256 duration = block.timestamp - data.lastUpdateTime;
        uint256 pending = duration * boostRate * 1e18 / _totalSupply;
        return
            data.rewardPerTokenStored + pending;
    }

    function earned(address account, address _rewardsToken) public view returns (uint256) {
        uint256 rpt = rewardPerToken(_rewardsToken) - userRewardPerTokenPaid[account][_rewardsToken];
        return derivedBalances[account] * rpt / 1e18 + rewards[account][_rewardsToken];
    }

    function earnedPoints(address account) public view returns (uint256) {
        uint256 rpt = pointsPerToken() - userPointsPerTokenPaid[account];
        return balanceOf[account] * rpt / 1e18 + pointRewards[account];
    }

    function getRewardForDuration(address _rewardsToken) external view returns (uint256) {
        return rewardData[_rewardsToken].rewardRate * REWARDS_DURATION;
    }

    function stake(uint256 amount) external updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        // Update the current point reward data
        boostAccounting.rewardPerTokenStored = pointsPerToken();
        boostAccounting.lastUpdateTime = block.timestamp;
        pointRewards[msg.sender] = earnedPoints(msg.sender);
        userPointsPerTokenPaid[msg.sender] = boostAccounting.rewardPerTokenStored;

        // Update balances.
        totalSupply += amount;
        balanceOf[msg.sender] += amount;

        // Update point distribution rate.
        uint256 _totalSupply = totalSupply;
        if(_totalSupply != 0) {
            uint256 _newRate = (((_totalSupply / 2) / 365 days) / 24 hours);
            boostRate = _newRate;
            emit RateAdjusted(_newRate);
        }

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf[msg.sender]);
        getReward();
    }

    function withdraw(uint256 amount) public updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        // Update the current point reward data
        boostAccounting.rewardPerTokenStored = pointsPerToken();
        boostAccounting.lastUpdateTime = block.timestamp;

        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        boostBalance[msg.sender] = 0; // Reset boost points to 0.

        // Update point distribution rate.
        uint256 _totalSupply = totalSupply;
        if(_totalSupply != 0) {
            uint256 _newRate = (((_totalSupply / 2) / 365 days) / 24 hours);
            boostRate = _newRate;
            emit RateAdjusted(_newRate);
        }

        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function kick(address account) public {
        uint256 _derivedBalance = derivedBalances[account];
        derivedSupply = derivedSupply - _derivedBalance;
        _derivedBalance = derivedBalance(account);
        derivedBalances[account] = _derivedBalance;
        derivedSupply += _derivedBalance;
    }

    function getReward() public updateReward(msg.sender) {
        // Update the current point reward data
        boostAccounting.rewardPerTokenStored = pointsPerToken();
        boostAccounting.lastUpdateTime = block.timestamp;
        pointRewards[msg.sender] = earnedPoints(msg.sender);
        userPointsPerTokenPaid[msg.sender] = boostAccounting.rewardPerTokenStored;

        // Update point balance.
        uint256 pointReward = pointRewards[msg.sender];
        if(pointReward > 0) {
            pointRewards[msg.sender] = 0;
            boostBalance[msg.sender] += pointReward;
            boostPointSupply += pointReward;
            emit PointsPaid(msg.sender, pointReward);
        }

        address[2] memory _rewardTokens = rewardTokens;
        for (uint256 i; i < _rewardTokens.length;) {
            address token = _rewardTokens[i];
            Reward storage r = rewardData[token];
            if (block.timestamp + REWARDS_DURATION > r.periodFinish + 3600) {
                // if last reward update was more than 1 hour ago, check for new rewards
                uint256 unseen = IERC20(token).balanceOf(address(this)) - r.balance;
                _notifyRewardAmount(r, unseen);
                emit RewardAdded(token, unseen);
            }
            uint256 reward = rewards[msg.sender][token];
            if (reward > 0) {
                rewards[msg.sender][token] = 0;
                r.balance -= reward;
                IERC20(token).safeTransfer(msg.sender, reward);
                emit RewardPaid(msg.sender, token, reward);
            }
            unchecked { ++i; }
        }
    }

    function derivedBalance(address account) public view returns (uint) {
        uint _balance = balanceOf[account];
        uint _derived = ((_balance * 40) / 100);
        uint _adjusted = ((((totalSupply * boostBalance[account]) / boostPointSupply) * 60) / 100);
        return Math.min((_derived + _adjusted), _balance);
    }

    function _notifyRewardAmount(Reward storage r, uint256 reward) internal {
        if (block.timestamp >= r.periodFinish) {
            r.rewardRate = reward / REWARDS_DURATION;
        } else {
            uint256 remaining = r.periodFinish - block.timestamp;
            uint256 leftover = remaining * r.rewardRate;
            r.rewardRate = (reward + leftover) / REWARDS_DURATION;
        }
        r.lastUpdateTime = block.timestamp;
        r.periodFinish = block.timestamp + REWARDS_DURATION;
        r.balance += reward;
    }

    modifier updateReward(address account) {
        address[2] memory _rewardTokens = rewardTokens;
        for (uint256 i; i < _rewardTokens.length;) {
            address token = _rewardTokens[i];
            rewardData[token].rewardPerTokenStored = rewardPerToken(token);
            rewardData[token].lastUpdateTime = lastTimeRewardApplicable(token);
            if (account != address(0)) {
                rewards[account][token] = earned(account, token);
                userRewardPerTokenPaid[account][token] = rewardData[token].rewardPerTokenStored;
            }
            unchecked { ++i; }
        }
        _;
        if(account != address(0)) {
            // Update the user's boost.
            kick(account);
        }
    }
}
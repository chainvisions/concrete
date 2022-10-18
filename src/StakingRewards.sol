// SPDX-License-Identifier: MIT 
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title StakingRewards
/// @author Chainvisions, forked from Solidex
/// @notice Contract for distributing rewards to stakers.

contract StakingRewards is Ownable {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    struct Reward {
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
        uint256 balance;
    }
    IERC20 public stakingToken;
    address[2] public rewardTokens;
    mapping(address => Reward) public rewardData;

    // user -> reward token -> amount
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    uint256 public constant REWARDS_DURATION = 86400 * 7;

    event RewardAdded(address indexed rewardsToken, uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, address indexed rewardsToken, uint256 reward);

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
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            return data.rewardPerTokenStored;
        }
        uint256 duration = lastTimeRewardApplicable(_rewardsToken) - data.lastUpdateTime;
        uint256 pending = duration * data.rewardRate * 1e18 / _totalSupply;
        return
            data.rewardPerTokenStored + pending;
    }

    function earned(address account, address _rewardsToken) public view returns (uint256) {
        uint256 rpt = rewardPerToken(_rewardsToken) - userRewardPerTokenPaid[account][_rewardsToken];
        return balanceOf[account] * rpt / 1e18 + rewards[account][_rewardsToken];
    }

    function getRewardForDuration(address _rewardsToken) external view returns (uint256) {
        return rewardData[_rewardsToken].rewardRate * REWARDS_DURATION;
    }

    function stake(uint256 amount) external updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public updateReward(msg.sender) {
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

    function exit() external {
        withdraw(balanceOf[msg.sender]);
        getReward();
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
    }
}
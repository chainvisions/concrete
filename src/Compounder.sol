// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeTransferLib} from "./lib/SafeTransferLib.sol";
import {IRockToken} from "./interfaces/concrete/IRockToken.sol";
import {IStakingRewards} from "./interfaces/concrete/IStakingRewards.sol";

/// @title Concrete Autocompounder
/// @author Chainvisions
/// @notice A vault contract that compounds ROCK tokens.

contract Compounder is ERC20 {
    using SafeTransferLib for IERC20;

    /// @notice Underlying token of the compounder.
    IERC20 public immutable UNDERLYING;

    /// @notice SOLID token contract.
    IERC20 public immutable SOLID;

    /// @notice ROCK token contract.
    IERC20 public immutable ROCK;

    /// @notice Staking rewards contract.
    IStakingRewards public immutable STAKING_REWARDS;

    /// @notice ROCK pair for rebasing.
    address public immutable ROCK_PAIR;

    /// @notice Contracts that can deposit into the compounder.
    mapping(address => bool) public permittedContracts;

    /// @notice Emitted when a deposit is made.
    /// @param user Address of the user.
    /// @param amount Amount deposited.
    /// @param timestamp Timestamp of the deposit.
    event Deposited(address indexed user, uint256 amount, uint256 timestamp);

    /// @notice Emitted when a withdrawal is made.
    /// @param user Address of the user.
    /// @param amount Amount withdrawn.
    /// @param timestamp Timestamp of the withdrawal.
    event Withdrawal(address indexed user, uint256 amount, uint256 timestamp);

    /// @notice Emitted when a harvest is performed.
    /// @param timestamp Timestamp of the harvest.
    event Harvest(uint256 timestamp);

    /// @notice Modifier to defend against flashloan attacks.
    modifier defense {
        require(tx.origin == msg.sender || permittedContracts[msg.sender], "Not a permitted contract");
        _;
    }

    /// @notice Constructor for the compounder.
    /// @param _underlying The address of the underlying token.
    /// @param _solid The address of the SOLID token.
    /// @param _rock The address of the ROCK token.
    /// @param _stakingRewards The address of the staking rewards contract.
    /// @param _rockPair The address of the ROCK pair for rebases.
    constructor(
        address _underlying,
        address _solid,
        address _rock,
        address _stakingRewards,
        address _rockPair
    ) ERC20(string.concat("Concrete Compounded ", ERC20(_underlying).name()), string.concat("rk-", ERC20(_underlying).symbol())) {
        UNDERLYING = IERC20(_underlying);
        SOLID = IERC20(_solid);
        ROCK = IERC20(_rock);
        STAKING_REWARDS = IStakingRewards(_stakingRewards);
        ROCK_PAIR = _rockPair;

        // Max approve the staking rewards contract. This is safe because type(uint256).max is a unattainable number.
        UNDERLYING.safeApprove(_stakingRewards, type(uint256).max);
    }

    /// @notice Deposits tokens into the compounder.
    /// @param _amount Amount of tokens to deposit.
    function deposit(uint256 _amount) external defense {
        uint256 toMint = totalSupply() == 0 ? _amount : _amount * totalSupply() / underlyingBalanceWithInvestment();
        _mint(msg.sender, toMint);
        UNDERLYING.transferFrom(msg.sender, address(this), _amount);
        emit Deposited(msg.sender, _amount, block.timestamp);
    }

    /// @notice Withdraws tokens from the compounder.
    /// @param _amount Amount of tokens to withdraw.
    function withdraw(uint256 _amount) external defense {
        require(_amount > 0, "Amount must be greater than 0");
        uint256 supplySnapshot = totalSupply();
        _burn(msg.sender, _amount);

        // Withdraw from staking rewards contract.
        uint256 balanceSnapshot = UNDERLYING.balanceOf(address(this));
        uint256 toWithdraw = ((balanceSnapshot + STAKING_REWARDS.balanceOf(address(this))) * _amount) / supplySnapshot;
        if(toWithdraw > balanceSnapshot) {
            if(_amount == supplySnapshot) {
                // If it's the last withdrawal, withdraw all.
                STAKING_REWARDS.exit();
            } else {
                // Otherwise, withdraw the amount.
                STAKING_REWARDS.withdraw(toWithdraw - balanceSnapshot);
            }
            // Recalculate the amount to send.
            toWithdraw = Math.min((underlyingBalanceWithInvestment() * _amount) / supplySnapshot, UNDERLYING.balanceOf(address(this)));
        }

        // Send the tokens.
        UNDERLYING.transfer(msg.sender, toWithdraw);
        emit Withdrawal(msg.sender, _amount, block.timestamp);
    }

    /// @notice Harvests and compounds rewards.
    function doHardWork() external {
        STAKING_REWARDS.getReward();
        uint256 rockBalance = ROCK.balanceOf(address(this));
        uint256 solidBalance = SOLID.balanceOf(address(this));

        // Perform the swap.
        // TODO: Implement swap via Solidly Router.
        solidBalance;

        // Rebase ROCK supply.
        IRockToken(address(ROCK)).rebase(ROCK_PAIR, rockBalance - ((rockBalance * 20) / 10000));

        // Deposit tokens into the staking rewards contract.
        uint256 underlyingBalance = UNDERLYING.balanceOf(address(this));
        if(underlyingBalance > 0) {
            STAKING_REWARDS.stake(underlyingBalance);
        }
        emit Harvest(block.timestamp);
    }

    /// @notice Helper function to calculate the gas limit that should be used for harvesting.
    /// @return Gas to use for performing a harvest on the compounder.
    function computeHarvestCost() external returns (uint256) {
        uint256 startGas = gasleft();
        Compounder(address(this)).doHardWork();
        return startGas - gasleft();
    }

    /// @notice Calculates the share price of the vault token.
    /// @return The vault's price per share.
    function getPricePerFullShare() external view returns (uint256) {
        return totalSupply() == 0
            ? 10 ** decimals() 
            : ((10 ** decimals()) * underlyingBalanceWithInvestment()) / totalSupply();
    }

    /// @notice Calculates the total amount of assets in the compounder.
    /// @return The total amount of assets in the compounder. Including staked tokens.
    function underlyingBalanceWithInvestment() public view returns (uint256) {
        return UNDERLYING.balanceOf(address(this)) + STAKING_REWARDS.balanceOf(address(this));
    }

    /// @notice Overridden function for matching the underlying token's decimals.
    /// @return The decimals of the vault share token.
    function decimals() public view override returns (uint8) {
        return ERC20(address(UNDERLYING)).decimals();
    }
}
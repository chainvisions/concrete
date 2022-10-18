// SPDX-License-Identifier: MIT 
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IBaseV1Voter} from "./interfaces/solidly/IBaseV1Voter.sol";
import {Cast} from "./lib/Cast.sol";
import {IGauge} from "./interfaces/solidly/IGauge.sol";
import {IBribe} from "./interfaces/solidly/IBribe.sol";
import {IVotingEscrow} from "./interfaces/solidly/IVotingEscrow.sol";
import {IFeeDistributor} from "./interfaces/concrete/IFeeDistributor.sol";
import {IRockToken} from "./interfaces/concrete/IRockToken.sol";
import {IDepositToken} from "./interfaces/concrete/ILpDepositToken.sol";
import {IVeDepositor} from "./interfaces/concrete/IVeDepositor.sol";

/// @title Concrete LP Depositor
/// @author Chainvisions, forked from Solidex
/// @notice Contract for depositing liquidity provider tokens into Concrete.

contract LpDepositor is Ownable {
    using Cast for uint256;
    using SafeERC20 for IERC20;

    /// @notice Structure for keeping track of reward amounts.
    struct Amounts {
        uint128 solid;
        uint128 rock;
    }

    /// @notice SOLID token contract.
    IERC20 public immutable SOLID;

    /// @notice ROCK token contract.
    IRockToken public immutable ROCK;

    /// @notice Solidly veNFT/Voting Escrow contract.
    IVotingEscrow public immutable votingEscrow;

    /// @notice Solidly voting contract.
    IBaseV1Voter public immutable solidlyVoter;

    /// @notice rockSOLID token contract.
    IVeDepositor public rockSOLID;
    
    /// @notice Contract for distributing Concrete fees.
    IFeeDistributor public feeDistributor;

    /// @notice StakingRewards contract for staking rockSOLID.
    address public stakingRewards;

    /// @notice Concrete whitelister contract.
    address public tokenWhitelister;

    /// @notice Implementation for Concrete deposit receipts.
    address public depositTokenImplementation;

    /// @notice Token ID for Concrete's veNFT.
    uint256 public tokenID;

    /// @notice Gauge contract for each Solidly pool.
    mapping(address => address) public gaugeForPool;

    /// @notice Bribe contract for each Solidly pool.
    mapping(address => address) public bribeForPool;

    /// @notice Concrete deposit token for each Solidly pool.
    mapping(address => address) public tokenForPool;

    /// @notice User deposits for each Solidly pool.
    mapping(address => mapping(address => uint256)) public userBalances;

    /// @notice Total deposited tokens for each Solidly pool.
    mapping(address => uint256) public totalBalances;

    /// @notice Reward integrals for each Solidly pool.
    mapping(address => Amounts) public rewardIntegral;

    /// @notice Last recorded reward integrals per user for each Solidly pool.
    mapping(address => mapping(address => Amounts)) public rewardIntegralFor;

    /// @notice Claimable rewards for each Solidly pool for a user.
    mapping(address => mapping(address => Amounts)) claimable;

    // internal accounting to track SOLID fees for rockSOLID stakers and ROCK lockers
    uint256 unclaimedSolidBonus;

    event RewardAdded(address indexed rewardsToken, uint256 reward);
    event Deposited(address indexed user, address indexed pool, uint256 amount);
    event Withdrawn(address indexed user, address indexed pool, uint256 amount);
    event RewardPaid(address indexed user, address indexed rewardsToken, uint256 reward);
    event TransferDeposit(address indexed pool, address indexed from, address indexed to, uint256 amount);

    /// @notice Constructor for the LpDepositor contract.
    /// @param _solid SOLID token contract.
    /// @param _rock ROCK token contract.
    /// @param _votingEscrow Solidly veNFT/Voting Escrow contract.
    /// @param _solidlyVoter Solidly voting contract.
    constructor(
        IERC20 _solid,
        IRockToken _rock,
        IVotingEscrow _votingEscrow,
        IBaseV1Voter _solidlyVoter

    ) {
        SOLID = _solid;
        ROCK = _rock;
        votingEscrow = _votingEscrow;
        solidlyVoter = _solidlyVoter;
    }

    /// @notice Sets remaining contract addresses.
    /// @param _rockSolid rockSOLID token contract.
    /// @param _rockVoter ROCK voting contract.
    /// @param _feeDistributor Contract for distributing Concrete fees.
    /// @param _stakingRewards StakingRewards contract for staking rockSOLID.
    /// @param _tokenWhitelister Concrete whitelister contract.
    /// @param _depositToken Implementation for Concrete deposit receipts.
    function setAddresses(
        IVeDepositor _rockSolid,
        address _rockVoter,
        IFeeDistributor _feeDistributor,
        address _stakingRewards,
        address _tokenWhitelister,
        address _depositToken
    ) external onlyOwner {
        rockSOLID = _rockSolid;
        feeDistributor = _feeDistributor;
        stakingRewards = _stakingRewards;
        tokenWhitelister = _tokenWhitelister;
        depositTokenImplementation = _depositToken;

        SOLID.approve(address(_rockSolid), type(uint256).max);
        _rockSolid.approve(address(_feeDistributor), type(uint256).max);
        votingEscrow.setApprovalForAll(_rockVoter, true);
        votingEscrow.setApprovalForAll(address(_rockSolid), true);

        renounceOwnership();
    }

    /// @notice Whitelists protocol tokens.
    function whitelistProtocolTokens() external {
        require(tokenID != 0, "No initial NFT deposit");
        if (!solidlyVoter.isWhitelisted(address(SOLID))) {
            solidlyVoter.whitelist(address(SOLID), tokenID);
        }
        if (!solidlyVoter.isWhitelisted(address(rockSOLID))) {
            solidlyVoter.whitelist(address(rockSOLID), tokenID);
        }
        if (!solidlyVoter.isWhitelisted(address(ROCK))) {
            solidlyVoter.whitelist(address(ROCK), tokenID);
        }
    }

    /**
        @notice Get pending SOLID and ROCK rewards earned by `account`
        @param account Account to query pending rewards for
        @param pools List of pool addresses to query rewards for
        @return pending Array of tuples of (SOLID rewards, ROCK rewards) for each item in `pool`
     */
    /// @notice Calculates the pending SOLID and ROCK rewards for a user.
    /// @param _account User to calculate rewards for.
    /// @param _pools List of pools to calculate rewards from.
    function pendingRewards(
        address _account,
        address[] calldata _pools
    )
        external
        view
        returns (Amounts[] memory pending)
    {
        pending = new Amounts[](_pools.length);
        for (uint256 i; i < _pools.length;) {
            address pool = _pools[i];
            pending[i] = claimable[_account][pool];
            uint256 balance = userBalances[_account][pool];
            if (balance == 0) continue;

            Amounts memory integral = rewardIntegral[pool];
            uint256 total = totalBalances[pool];
            if (total > 0) {
                uint256 delta = IGauge(gaugeForPool[pool]).earned(address(SOLID), address(this));
                delta -= delta * 15 / 100;
                integral.solid += (1e18 * delta / total).u128();
                integral.rock += (1e18 * (delta * 10000 / 42069) / total).u128();
            }

            Amounts storage integralFor = rewardIntegralFor[_account][pool];
            if (integralFor.solid < integral.solid) {
                pending[i].solid += (balance * (integral.solid - integralFor.solid) / 1e18).u128();
                pending[i].rock += (balance * (integral.rock - integralFor.rock) / 1e18).u128();
            }
            unchecked { ++i; }
        }
        return pending;
    }

    /// @notice Deposits Solidly LP tokens into a gauge.
    /// @param _pool Address of the pool to deposit to.
    /// @param _amount Quantity of tokens to deposit.
    function deposit(address _pool, uint256 _amount) external {
        require(tokenID != 0, "Must lock SOLID first");
        require(_amount > 0, "Cannot deposit zero");

        address gauge = gaugeForPool[_pool];
        uint256 total = totalBalances[_pool];
        uint256 balance = userBalances[msg.sender][_pool];

        if (gauge == address(0)) {
            gauge = solidlyVoter.gauges(_pool);
            if (gauge == address(0)) {
                gauge = solidlyVoter.createGauge(_pool);
            }
            gaugeForPool[_pool] = gauge;
            bribeForPool[_pool] = solidlyVoter.bribes(gauge);
            tokenForPool[_pool] = _deployDepositToken(_pool);
            IERC20(_pool).approve(gauge, type(uint256).max);
        } else {
            _updateIntegrals(msg.sender, _pool, gauge, balance, total);
        }

        IERC20(_pool).transferFrom(msg.sender, address(this), _amount);
        IGauge(gauge).deposit(_amount, tokenID);

        userBalances[msg.sender][_pool] = balance + _amount;
        totalBalances[_pool] = total + _amount;
        IDepositToken(tokenForPool[_pool]).mint(msg.sender, _amount);
        emit Deposited(msg.sender, _pool, _amount);
    }

    /// @notice Withdraws Solidly LP tokens from a gauge.
    /// @param _pool Address of the pool to withdraw from.
    /// @param _amount Quantity of tokens to withdraw.
    function withdraw(address _pool, uint256 _amount) external {
        address gauge = gaugeForPool[_pool];
        uint256 total = totalBalances[_pool];
        uint256 balance = userBalances[msg.sender][_pool];

        require(gauge != address(0), "Unknown pool");
        require(_amount > 0, "Cannot withdraw zero");
        require(balance >= _amount, "Insufficient deposit");

        _updateIntegrals(msg.sender, _pool, gauge, balance, total);

        userBalances[msg.sender][_pool] = balance - _amount;
        totalBalances[_pool] = total - _amount;

        IDepositToken(tokenForPool[_pool]).burn(msg.sender, _amount);
        IGauge(gauge).withdraw(_amount);
        IERC20(_pool).transfer(msg.sender, _amount);
        emit Withdrawn(msg.sender, _pool, _amount);
    }

    /// @notice Claims SOLID and ROCK rewards.
    /// @param _pools List of pools to claim rewards from.
    function getReward(address[] calldata _pools) external {
        Amounts memory claims;
        for (uint256 i; i < _pools.length;) {
            address pool = _pools[i];
            address gauge = gaugeForPool[pool];
            uint256 total = totalBalances[pool];
            uint256 balance = userBalances[msg.sender][pool];
            _updateIntegrals(msg.sender, pool, gauge, balance, total);
            claims.solid += claimable[msg.sender][pool].solid;
            claims.rock += claimable[msg.sender][pool].rock;
            delete claimable[msg.sender][pool];
            unchecked { ++i; }
        }
        if (claims.solid > 0) {
            SOLID.transfer(msg.sender, claims.solid);
            emit RewardPaid(msg.sender, address(SOLID), claims.solid);
        }
        if (claims.rock > 0) {
            ROCK.mint(msg.sender, claims.rock);
            emit RewardPaid(msg.sender, address(ROCK), claims.rock);
            // mint an extra 5% for rockSOLID stakers
            ROCK.mint(address(stakingRewards), claims.rock * 100 / 95 - claims.rock);
            emit RewardPaid(address(stakingRewards), address(ROCK), claims.rock * 100 / 95 - claims.rock);
        }
    }

    /// @notice Splits the veNFT into two NFTs.
    /// @param _amount Amount of rockSOLID to burn to create the new NFT.
    function split(uint256 _amount) external {
        (bool s_,) = address(rockSOLID).call(abi.encodeWithSignature("burnFrom(address,uint256)", msg.sender, _amount));
        require(s_);
        // Send split NFT to msg.sender
        (bool s__,) = address(votingEscrow).call(abi.encodeWithSignature("split(uint256,uint256, address)", tokenID, _amount, msg.sender));
        require(s__);
    }

    /// @notice Claims rewards from gauges and bribes for ROCK lockers.
    /// @param _pool Address of the pool to claim rewards from.
    /// @param _gaugeRewards Reward tokens to claim from the gauge.
    /// @param _bribeRewards Reward tokens to claim from bribes.
    function claimLockerRewards(
        address _pool,
        address[] calldata _gaugeRewards,
        address[] calldata _bribeRewards
    ) external {
        // claim pending gauge rewards for this pool to update `unclaimedSolidBonus`
        address gauge = gaugeForPool[_pool];
        require(gauge != address(0), "Unknown pool");
        _updateIntegrals(address(0), _pool, gauge, 0, totalBalances[_pool]);

        address distributor = address(feeDistributor);
        uint256 amount;

        // fetch gauge rewards and push to the fee distributor
        if (_gaugeRewards.length > 0) {
            IGauge(gauge).getReward(address(this), _gaugeRewards);
            for (uint256 i; i < _gaugeRewards.length;) {
                IERC20 reward = IERC20(_gaugeRewards[i]);
                require(reward != SOLID, "!SOLID as gauge reward");
                amount = IERC20(reward).balanceOf(address(this));
                if (amount == 0) continue;
                if (reward.allowance(address(this), distributor) == 0) {
                    reward.safeApprove(distributor, type(uint256).max);
                }
                IFeeDistributor(distributor).depositFee(address(reward), amount);
                unchecked { ++i; }
            }
        }

        // fetch bribe rewards and push to the fee distributor
        if (_bribeRewards.length > 0) {
            uint256 solidBalance = SOLID.balanceOf(address(this));
            IBribe(bribeForPool[_pool]).getReward(tokenID, _bribeRewards);
            for (uint256 i; i < _bribeRewards.length;) {
                IERC20 reward = IERC20(_bribeRewards[i]);
                if (reward == SOLID) {
                    // when SOLID is received as a bribe, add it to the balance
                    // that will be converted to rockSOLID prior to distribution
                    uint256 newBalance = SOLID.balanceOf(address(this));
                    unclaimedSolidBonus += newBalance - solidBalance;
                    solidBalance = newBalance;
                    continue;
                }
                amount = reward.balanceOf(address(this));
                if (amount == 0) continue;
                if (reward.allowance(address(this), distributor) == 0) {
                    reward.safeApprove(distributor, type(uint256).max);
                }
                IFeeDistributor(distributor).depositFee(address(reward), amount);
                unchecked { ++i; }
            }
        }

        amount = unclaimedSolidBonus;
        if (amount > 0) {
            // lock 5% of earned SOLID and distribute rockSOLID to ROCK lockers
            uint256 lockAmount = amount / 3;
            rockSOLID.depositTokens(lockAmount);
            IFeeDistributor(distributor).depositFee(address(rockSOLID), lockAmount);

            // distribute 10% of earned SOLID to rockSOLID stakers
            amount -= lockAmount;
            SOLID.transfer(address(stakingRewards), amount);
            unclaimedSolidBonus = 0;
        }
    }

    /// @notice Function for protocol contracts to transfer Concrete deposits.
    /// @param _pool Address of the pool to transfer deposits from.
    /// @param _from Address of the sender.
    /// @param _to Address of the recipient.
    /// @param _amount Amount of tokens to transfer.
    function transferDeposit(address _pool, address _from, address _to, uint256 _amount) external returns (bool) {
        require(msg.sender == tokenForPool[_pool], "Unauthorized caller");
        require(_amount > 0, "Cannot transfer zero");

        address gauge = gaugeForPool[_pool];
        uint256 total = totalBalances[_pool];

        uint256 balance = userBalances[_from][_pool];
        require(balance >= _amount, "Insufficient balance");
        _updateIntegrals(_from, _pool, gauge, balance, total);
        userBalances[_from][_pool] = balance - _amount;

        balance = userBalances[_to][_pool];
        _updateIntegrals(_to, _pool, gauge, balance, total - _amount);
        userBalances[_to][_pool] = balance + _amount;
        emit TransferDeposit(_pool, _from, _to, _amount);
        return true;
    }

    /// @notice Whitelists a token on Solidly.
    /// @param _token Token to whitelist.
    /// @return Whether or not the token was whitelisted.
    function whitelist(address _token) external returns (bool) {
        require(msg.sender == tokenWhitelister, "Only whitelister");
        require(votingEscrow.balanceOfNFT(tokenID) > solidlyVoter.listing_fee(), "Not enough veSOLID");
        solidlyVoter.whitelist(_token, tokenID);
        return true;
    }

    /// @notice Hook for handling ERC721 transfers into this contract.
    /// @param _operator The address that sent the NFT. Should be rockSOLID.
    /// @param _from Unused field.
    /// @param _tokenID The ID of the NFT being transferred.
    /// @return Standard hook return value. "bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))"
    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenID,
        bytes calldata
    ) external returns (bytes4) {
        _from;
        // VeDepositor transfers the NFT to this contract so this callback is required
        require(_operator == address(rockSOLID));

        if (tokenID == 0) {
            tokenID = _tokenID;
        }

        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }

    // ** Internal functions ** //

    function _deployDepositToken(address pool) internal returns (address token) {
        // taken from https://solidity-by-example.org/app/minimal-proxy/
        bytes20 targetBytes = bytes20(depositTokenImplementation);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            token := create(0, clone, 0x37)
        }
        IDepositToken(token).initialize(pool);
        return token;
    }

    function _updateIntegrals(
        address user,
        address pool,
        address gauge,
        uint256 balance,
        uint256 total
    ) internal {
        Amounts memory integral = rewardIntegral[pool];
        if (total > 0) {
            uint256 delta = SOLID.balanceOf(address(this));
            address[] memory rewards = new address[](1);
            rewards[0] = address(SOLID);
            IGauge(gauge).getReward(address(this), rewards);
            delta = SOLID.balanceOf(address(this)) - delta;
            if (delta > 0) {
                uint256 fee = delta * 15 / 100;
                delta -= fee;
                unclaimedSolidBonus += fee;

                integral.solid += (1e18 * delta / total).u128();
                integral.rock += (1e18 * (delta * 10000 / 42069) / total).u128();
                rewardIntegral[pool] = integral;
            }
        }
        if (user != address(0)) {
            Amounts memory integralFor = rewardIntegralFor[user][pool];
            if (integralFor.solid < integral.solid) {
                Amounts storage claims = claimable[user][pool];
                claims.solid += (balance * (integral.solid - integralFor.solid) / 1e18).u128();
                claims.rock += (balance * (integral.rock - integralFor.rock) / 1e18).u128();
                rewardIntegralFor[user][pool] = integral;
            }
        }
    }
}
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Cast} from "./lib/Cast.sol";
import {SafeTransferLib} from "./lib/SafeTransferLib.sol";

/// @title Concrete Layer 2 Bribe Manager
/// @author Chainvisions
/// @notice Contract for managing bribes for vlROCK holders.

contract L2BribeManager is Ownable {
    using Cast for uint256;
    using SafeTransferLib for IERC20;

    /// @notice Structure for merkle claim data.
    struct MerkleClaim {
        address pool;
        address token;
        uint256 epoch;
        uint256 idx;
        address account;
        uint256 amount;
        bytes32[] merkleProof;
    }

    /// @notice Latest bribe epoch.
    uint256 latestEpoch;

    /// @notice Percentage of bribes to be distributed to rockSOLO holders.
    uint256 rockSolidPercentage;

    /// @notice Packed array of booleans for tracking claimed bribes. [pool][token][epoch][index]
    mapping(address => mapping(address => mapping(uint256 => mapping(uint256 => uint256)))) public claimedBitMapForToken;

    /// @notice Merkle root for a token at a given epoch. [pool][token][epoch]
    mapping(address => mapping(address => mapping(uint256 => bytes32))) public merkleRootForToken;

    /// @notice Emitted when a bribe is deposited.
    /// @param pool Solidly pool address.
    /// @param token Token deposited as a bribe.
    /// @param epoch Epoch for which the bribe is valid.
    /// @param amount Amount of tokens deposited.
    event BribeDeposited(address indexed pool, address indexed token, uint256 indexed epoch, uint256 amount);

    /// @notice Emitted when a bribe is claimed.
    /// @param pool Solidly pool address.
    /// @param token Token deposited as a bribe.
    /// @param epoch Epoch for which the bribe is valid.
    /// @param Account Address of the account that claimed the bribe.
    /// @param amount Amount of tokens claimed.
    event BribeClaimed(address indexed pool, address indexed token, uint256 indexed epoch, address indexed account, uint256 amount);

    /// @notice Deposits a bribe for a specific Solidly pool.
    /// @param _pool Solidly pool address.
    /// @param _token Token deposited as a bribe.
    /// @param _amount Amount of tokens to distribute.
    function depositBribe(
        address _pool,
        IERC20 _bribe,
        uint256 _amount
    ) external {
        require(_amount > 0, "Amount must not be 0");
        _bribe.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 rockSolidAmount = (_amount * rockSolidPercentage) / 10000;
        // TODO: Send fee to rockSOLID.
        emit BribeDeposited(_pool, address(_bribe), latestEpoch, _amount - rockSolidAmount);
    }

    /// @notice Sets the merkle root for a token at a given epoch.
    /// @param _pool Solidly pool address.
    /// @param _token Token deposited as a bribe.
    /// @param _epoch Epoch for which the bribe is valid.
    /// @param _merkleRoot Merkle root for the given epoch.
    function setMerkleForBribe(
        address _pool,
        address _token,
        uint256 _epoch,
        bytes32 _merkleRoot
    ) external onlyOwner {
        require(merkleRootForToken[_pool][_token][_epoch] == bytes32(0), "Merkle root already set");
        merkleRootForToken[_pool][_token][_epoch] = _merkleRoot;
    }

    /// @notice Claims a bribe for a given epoch.
    /// @param _claim Merkle claim data.
    function claim(MerkleClaim calldata _claim) external {
        // Check if the claim has already been made.
        uint256 claimedWordIndex = _claim.idx / 256;
        uint256 claimedBitIndex = _claim.idx % 256;
        uint256 claimedWord = claimedBitMapForToken[_claim.pool][_claim.token][_claim.epoch][claimedWordIndex];
        uint256 mask = (1 << claimedBitIndex);
        bool hasClaimed = claimedWord & mask == mask;
        require(!hasClaimed, "Already claimed");

        // Verify the merkle proof.
        bytes32 node = keccak256(abi.encodePacked(_claim.idx, _claim.account, _claim.amount));
        require(MerkleProof.verify(_claim.merkleProof, merkleRootForToken[_claim.pool][_claim.token][_claim.epoch], node));

        // Mark it claimed and send the bribe.
        uint256 claimedWordIndex = _claim.idx / 256;
        uint256 claimedBitIndex = _claim.idx % 256;
        claimedBitMapForToken[_claim.pool][_claim.token][_claim.epoch][claimedWordIndex] = claimedBitMapForToken[_claim.pool][_claim.token][_claim.epoch][claimedWordIndex] | (1 << claimedBitIndex);
        IERC20(_claim.token).safeTransfer(_claim.account, _claim.amount);

        emit BribeClaimed(_claim.pool, _claim.token, _claim.epoch, _claim.account, _claim.amount);
    }

    /// @notice Claims multiple bribes at once.
    /// @param _claims Array of merkle claim data.
    function batchClaimBribes(MerkleClaim[] calldata _claims) external {
        for (uint256 i; i < _claims.length;) {
            MerkleClaim memory _claim = _claims[i];
            // Check if the claim has already been made.
            uint256 claimedWordIndex = _claim.idx / 256;
            uint256 claimedBitIndex = _claim.idx % 256;
            uint256 claimedWord = claimedBitMapForToken[_claim.pool][_claim.token][_claim.epoch][claimedWordIndex];
            uint256 mask = (1 << claimedBitIndex);
            bool hasClaimed = claimedWord & mask == mask;
            require(!hasClaimed, "Already claimed");

            // Verify the merkle proof.
            bytes32 node = keccak256(abi.encodePacked(_claim.idx, _claim.account, _claim.amount));
            require(MerkleProof.verify(_claim.merkleProof, merkleRootForToken[_claim.pool][_claim.token][_claim.epoch], node));

            // Mark it claimed and send the bribe.
            uint256 claimedWordIndex = _claim.idx / 256;
            uint256 claimedBitIndex = _claim.idx % 256;
            claimedBitMapForToken[_claim.pool][_claim.token][_claim.epoch][claimedWordIndex] = claimedBitMapForToken[_claim.pool][_claim.token][_claim.epoch][claimedWordIndex] | (1 << claimedBitIndex);
            IERC20(_claim.token).safeTransfer(_claim.account, _claim.amount);

            emit BribeClaimed(_claim.pool, _claim.token, _claim.epoch, _claim.account, _claim.amount);
            unchecked { ++i; }
        }
    }
}
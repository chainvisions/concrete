// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.16;

import {Cast} from "./lib/Cast.sol";
import {IMigrateable} from "./interfaces/concrete/IMigrateable.sol";
import {ITokenLocker} from "./interfaces/concrete/ITokenLocker.sol";

/// @title Concrete Mutability Governance
/// @author Chainvisions
/// @notice Contract for managing Concrete governance.

contract Governance {
    using Cast for uint256;

    /// @notice Enum for the state of governance proposals.
    enum ProposalStatus {
        Active,
        Passed,
        Failed,
        Executable
    }

    /// @notice Struct for gov votes.
    struct Vote {
        uint128 yes;
        uint128 no;
    }

    /// @notice Struct for governance parameters.
    struct GovernanceParameters {
        /// @notice Minimum quorum for a proposal to pass.
        uint16 minQuorum;
        /// @notice Max length a proposal can be active for.
        uint32 proposalDecay;
        /// @notice Time before a proposal is active.
        uint32 proposalDelay;
        /// @notice Address with the power to veto a proposal.
        address dictator;
        // Filled space for packing to 256 bits
        uint16 et_tu_brute;
    }

    /// @notice Struct for gov proposals.
    struct Proposal {
        /// @notice Current status of the proposal.
        ProposalStatus status;
        /// @notice Contract to be migrated.
        address toMigrate;
        /// @notice Contract to be migrated to.
        address proposedImplementation;
        /// @notice Votes for the proposal.
        Vote totalVote;
    }

    /// @notice Parameters for governance.
    GovernanceParameters public parameters;

    /// @notice All migration proposals.
    Proposal[] public proposals;

    /// @notice Vetoes a proposal.
    /// @param _proposalId ID of the proposal to veto.
    function veto(uint256 _proposalId) external {
        GovernanceParameters memory _parameters = parameters;
        Proposal memory _proposal = proposals[_proposalId];
        require(msg.sender == _parameters.dictator, "Not dictator");
        _proposal.status = ProposalStatus.Failed;
        delete proposals[_proposalId];
        proposals[_proposalId] = _proposal;
    }
}
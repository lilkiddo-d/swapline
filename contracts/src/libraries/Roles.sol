// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Role identifiers shared across Swapline contracts. DEFAULT_ADMIN_ROLE is always held by the Timelock.
library Roles {
    /// @notice Can pause immediately (unpausing is a Timelock action).
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Contracts allowed to call market liquidation entry points.
    bytes32 internal constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    /// @notice Factory allowed to register markets in the MarginEngine / LPPositions.
    bytes32 internal constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    /// @notice Compliance officer allowed to edit allowlists.
    bytes32 internal constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    /// @notice FeeCollector distributor.
    bytes32 internal constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";
import {Roles} from "../libraries/Roles.sol";

/// @title ComplianceRegistry
/// @notice Pluggable allowlist hook. OFF by default: while `enabled == false` every action is allowed.
///         When enabled, each gated action requires the account to be on the allowlist. Closing positions,
///         withdrawing, settling and liquidations are never gated (users can always exit).
contract ComplianceRegistry is IComplianceRegistry, AccessControl {
    uint256 public constant MAX_BATCH = 200;

    bool public enabled;
    mapping(Action => bool) public gated;
    mapping(address => bool) public allowlisted;

    event EnabledSet(bool enabled);
    event ActionGated(Action action, bool gated);
    event AllowlistUpdated(address indexed account, bool allowed);

    error BatchTooLarge();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        gated[Action.Trade] = true;
        gated[Action.ProvideLiquidity] = true;
        gated[Action.DepositMargin] = true;
        gated[Action.VaultDeposit] = true;
    }

    function isAllowed(address account, Action action) external view override returns (bool) {
        if (!enabled || !gated[action]) return true;
        return allowlisted[account];
    }

    function setEnabled(bool enabled_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = enabled_;
        emit EnabledSet(enabled_);
    }

    function setGated(Action action, bool gated_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        gated[action] = gated_;
        emit ActionGated(action, gated_);
    }

    function setAllowlisted(address[] calldata accounts, bool allowed) external onlyRole(Roles.COMPLIANCE_ROLE) {
        if (accounts.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < accounts.length; ++i) {
            allowlisted[accounts[i]] = allowed;
            emit AllowlistUpdated(accounts[i], allowed);
        }
    }
}

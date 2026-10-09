// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IComplianceRegistry {
    /// @notice Gated actions.
    enum Action {
        Trade,
        ProvideLiquidity,
        DepositMargin,
        VaultDeposit
    }

    function isAllowed(address account, Action action) external view returns (bool);
}

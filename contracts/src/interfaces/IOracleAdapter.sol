// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Swappable collateral pricing adapter.
interface IOracleAdapter {
    /// @return price USD price of `token`, 18 decimals. Reverts if stale or unsupported.
    function getPrice(address token) external view returns (uint256 price);

    /// @return true if the collateral price is fresh and within the allowed deviation from its peg.
    function isCollateralHealthy(address token) external view returns (bool);
}

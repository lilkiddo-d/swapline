// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice A yield source whose value grows through an on-chain exchange rate (share price / accumulator).
/// @dev Adapters normalise every source to an 18-decimal index (1e18 = 1.0). The index is expected to be
///      non-decreasing for a healthy source; a decrease is treated by RateOracle as an impairment signal.
interface IRateSource {
    /// @return index Current exchange-rate index, 18 decimals.
    function currentIndex() external view returns (uint256 index);

    /// @return value Total value held by the source, denominated in the source's underlying asset (native decimals).
    ///         Used to cap open interest relative to source size (donation-attack economics). 0 = unknown.
    function totalValue() external view returns (uint256 value);

    /// @return The underlying asset the index is denominated in (e.g. USDG).
    function underlying() external view returns (address);

    /// @return Human-readable description, e.g. "Steakhouse USDG (Morpho Vault V2)".
    function description() external view returns (string memory);
}

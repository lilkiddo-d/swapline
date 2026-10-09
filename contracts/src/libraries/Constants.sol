// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library Constants {
    uint256 internal constant WAD = 1e18;
    /// @dev Extra precision for position balances (variable shares and fixed cash are stored ×1e18).
    uint256 internal constant X18 = 1e18;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant BPS = 10_000;
    /// @dev Relative share-price drop tolerated as rounding before a source is flagged impaired (1e-6).
    uint256 internal constant IMPAIRMENT_TOLERANCE = 1e12;
}

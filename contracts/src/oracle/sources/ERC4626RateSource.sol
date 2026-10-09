// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IRateSource} from "../../interfaces/IRateSource.sol";

/// @title ERC4626RateSource
/// @notice Index = share price of an ERC-4626 vault (assets per share), normalised to 18 decimals.
/// @dev Uses a probe of 10^(shareDecimals+12) shares so that low-decimal assets (USDG has 6) keep 18 digits of
///      precision. Used for the Steakhouse USDG Morpho Vault V2 (steakUSDG), whose share price growth is bounded
///      on-chain by the vault's own `maxRate`.
contract ERC4626RateSource is IRateSource {
    IERC4626 public immutable vault;
    address public immutable override underlying;
    uint256 public immutable probeShares;
    uint256 public immutable assetScale;
    string private _description;

    error ZeroAddress();

    constructor(IERC4626 vault_, string memory description_) {
        if (address(vault_) == address(0)) revert ZeroAddress();
        vault = vault_;
        underlying = vault_.asset();
        probeShares = 10 ** (uint256(IERC20Metadata(address(vault_)).decimals()) + 12);
        assetScale = 10 ** (uint256(IERC20Metadata(underlying).decimals()) + 12);
        _description = description_;
    }

    function currentIndex() external view override returns (uint256) {
        return mulDiv(vault.convertToAssets(probeShares), 1e18, assetScale);
    }

    function totalValue() external view override returns (uint256) {
        return vault.totalAssets();
    }

    function description() external view override returns (string memory) {
        return _description;
    }
}

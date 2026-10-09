// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRateSource} from "../../interfaces/IRateSource.sol";

/// @notice Spark Savings Vault V2 (ERC-4626 with a Sky-style `chi` accumulator, RAY precision).
interface ISparkVault {
    function nowChi() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function asset() external view returns (address);
}

/// @title SparkVaultRateSource
/// @notice Index = Spark vault `nowChi()` (RAY) rescaled to 18 decimals. `totalAssets` is `totalSupply * chi`, so the
///         index is not affected by direct token donations to the vault.
contract SparkVaultRateSource is IRateSource {
    ISparkVault public immutable vault;
    address public immutable override underlying;
    string private _description;

    error ZeroAddress();

    constructor(ISparkVault vault_, string memory description_) {
        if (address(vault_) == address(0)) revert ZeroAddress();
        vault = vault_;
        underlying = vault_.asset();
        _description = description_;
    }

    function currentIndex() external view override returns (uint256) {
        return vault.nowChi() / 1e9;
    }

    function totalValue() external view override returns (uint256) {
        return vault.totalAssets();
    }

    function description() external view override returns (string memory) {
        return _description;
    }
}

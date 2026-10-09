// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapMarket} from "../interfaces/ISwapMarket.sol";

/// @title Liquidator
/// @notice Permissionless liquidation entry point. Anyone may liquidate an account below maintenance margin; the
///         market unwinds its exposure through the vAMM (bounded by `rateBand` slippage) and the caller receives
///         `liquidationRewardBps` of the account's maintenance requirement, paid from the account's margin.
contract Liquidator is AccessControl, ReentrancyGuard {
    uint256 public constant MAX_BATCH = 20;

    /// @notice Max rate move allowed while unwinding a liquidated position (18 decimals, e.g. 0.03e18 = 300bp).
    uint256 public rateBand;

    event RateBandSet(uint256 rateBand);
    event LiquidationFailed(address indexed market, address indexed account, bytes reason);

    error InvalidBand();
    error BatchTooLarge();

    constructor(address admin, uint256 rateBand_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setBand(rateBand_);
    }

    function liquidate(ISwapMarket market, address account) external nonReentrant returns (uint256 reward) {
        return market.liquidate(account, msg.sender, rateBand);
    }

    /// @notice Best-effort batch; failures are reported via events instead of reverting the batch.
    function liquidateMany(ISwapMarket market, address[] calldata accounts)
        external
        nonReentrant
        returns (uint256 totalReward)
    {
        if (accounts.length > MAX_BATCH) revert BatchTooLarge();
        uint256 band = rateBand;
        for (uint256 i; i < accounts.length; ++i) {
            try market.liquidate(accounts[i], msg.sender, band) returns (uint256 r) {
                totalReward += r;
            } catch (bytes memory reason) {
                emit LiquidationFailed(address(market), accounts[i], reason);
            }
        }
    }

    function setRateBand(uint256 rateBand_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setBand(rateBand_);
    }

    function _setBand(uint256 b) internal {
        if (b == 0 || b > 0.2e18) revert InvalidBand();
        rateBand = b;
        emit RateBandSet(b);
    }
}

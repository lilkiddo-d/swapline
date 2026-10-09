// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IComplianceRegistry} from "./IComplianceRegistry.sol";

interface IMarginEngine {
    struct RiskParams {
        uint256 imShock; // annualised rate move used for initial margin, 18 decimals (e.g. 0.03e18)
        uint256 mmShock; // annualised rate move used for maintenance margin
        uint256 minMargin; // flat requirement for any open position, token units
        uint256 minTau; // floor on time-to-maturity used in requirements, seconds
        uint256 liquidationRewardBps; // share of maintenance requirement paid to liquidators
        uint256 markInterval; // seconds between marks (daily mark-to-market)
    }

    struct Health {
        int256 equity; // margin + MTM value + uncollected fees (token units)
        uint256 initialRequirement;
        uint256 maintenanceRequirement;
        uint256 exposure; // variable notional exposure (token units)
    }

    function token() external view returns (IERC20);
    function paused() external view returns (bool);
    function marketPaused(address market) external view returns (bool);
    function isAllowed(address account, IComplianceRegistry.Action action) external view returns (bool);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function collateralHealthy() external view returns (bool);

    function marginOf(address market, address account) external view returns (uint256);
    function health(address market, address account) external view returns (Health memory);
    function isLiquidatable(address market, address account) external view returns (bool);

    function deposit(address market, address account, uint256 amount) external;
    function withdraw(address market, uint256 amount, address to) external;

    // market hooks
    function chargeFee(address account, uint256 fee, uint256 protocolFee) external;
    function creditLpFee(address account, uint256 amount) external;
    function checkInitialMargin(address account) external view;
    function settleAccount(address account, int256 cashflow) external;
    function payLiquidationReward(address account, address liquidator, uint256 maintenanceBefore)
        external
        returns (uint256 reward);
    function pokeIfDue(address market) external;
}

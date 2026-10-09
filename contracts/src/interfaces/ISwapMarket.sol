// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRateOracle} from "./IRateOracle.sol";

interface ISwapMarket {
    struct AccountState {
        int256 varSharesX18; // includes LP exposure accrued but not yet folded
        int256 fixedCashX18;
        uint256 lpUnfilledNotional; // worst-case additional variable notional from LP ranges (token units)
        uint256 lpFeesOwed; // uncollected LP fees (token units)
        bool hasPosition;
    }

    function oracle() external view returns (IRateOracle);
    function maturity() external view returns (uint256);
    function vamm() external view returns (address);
    function accountState(address account) external view returns (AccountState memory);
    function settled(address account) external view returns (bool);
    function currentRate() external view returns (uint256);
    function observe() external view returns (uint256 cumulative, uint256 timestamp);
    function liquidate(address account, address liquidator, uint256 rateBand) external returns (uint256 reward);
}

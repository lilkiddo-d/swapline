// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SwaplineFixture} from "../utils/SwaplineFixture.sol";
import {Handler} from "./Handler.sol";
import {ISwapMarket} from "../../src/interfaces/ISwapMarket.sol";
import {MarginEngine} from "../../src/core/MarginEngine.sol";
import {SwapMarket} from "../../src/core/SwapMarket.sol";

/// @notice Protocol-wide invariants under random trading, LP activity, time/yield (incl. donation spikes),
///         liquidations and settlement.
contract InvariantsTest is StdInvariant, SwaplineFixture {
    Handler handler;
    address[] actors;

    function setUp() public override {
        super.setUp();
        // use the 30-day market so random time steps reach maturity and settlement is exercised
        market = SwapMarket(d.markets[0].market);
        actors.push(alice);
        actors.push(bob);
        actors.push(carol);
        actors.push(lp1);
        actors.push(lp2);
        handler = new Handler(market, d.marginEngine, oracle, d.liquidator, usdg, yv, actors);
        // base liquidity so trades can execute
        _deposit(lp1, market, 500_000e6);
        _mint(lp1, market, 0, 1_500, 2e12);
        targetContract(address(handler));
    }

    /// @dev Sum over all accounts of variable shares and fixed cash (incl. LP accrued) nets to ~zero: every
    ///      trade has an equal and opposite LP side.
    function invariant_balancesNetToZero() public view {
        int256 sumVar;
        int256 sumFix;
        for (uint256 i; i < actors.length; ++i) {
            ISwapMarket.AccountState memory s = market.accountState(actors[i]);
            sumVar += s.varSharesX18;
            sumFix += s.fixedCashX18;
        }
        // rounding dust only (X18 precision, i.e. far below 1 wei of the token)
        assertApproxEqAbs(sumVar, 0, 1e15);
        assertApproxEqAbs(sumFix, 0, 1e15);
    }

    /// @dev Sum of all settlement cashflows is <= 0 (no value created) and only off by rounding dust.
    function invariant_settlementNetsToZeroMinusDust() public view {
        int256 total = handler.totalSettled();
        assertLe(total, 0);
        assertGe(total, -int256(handler.settledCount()) - 1);
    }

    /// @dev The margin engine never allows a risk-increasing position below initial margin.
    function invariant_noPositionOpenedBelowInitialMargin() public view {
        assertEq(handler.imViolations(), 0);
    }

    /// @dev Token solvency: custody >= sum of margins + LP fee pool + insurance (modulo bad debt recorded as deficit).
    function invariant_custodyCoversClaims() public view {
        uint256 claims;
        for (uint256 i; i < actors.length; ++i) {
            claims += d.marginEngine.marginOf(address(market), actors[i]);
        }
        MarginEngine.MarketInfo memory info = d.marginEngine.marketInfo(address(market));
        claims += info.lpFeePool + d.marginEngine.insuranceFund();
        assertGe(usdg.balanceOf(address(d.marginEngine)) + d.marginEngine.deficit(), claims);
    }

    /// @dev Oracle index never exceeds the max-rate envelope from its first observation (donations are clamped).
    function invariant_oracleIndexWithinEnvelope() public view {
        uint256 first = 1e18; // fixture source starts at share price ~1.0
        uint256 elapsed = block.timestamp - START;
        uint256 maxIdx = first + (first * oracle.maxRatePerYear() * elapsed) / (365 days * 1e18) + 1e15;
        // compounding of per-period caps can exceed the simple envelope slightly: allow 5% of the excess
        assertLe(oracle.latestObservation().index, maxIdx + (maxIdx - first) / 20 + 1e12);
    }

    function invariant_callSummary() public view {
        handler.calls();
    }
}


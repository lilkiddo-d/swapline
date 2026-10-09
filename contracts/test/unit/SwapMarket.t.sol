// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SwaplineFixture} from "../utils/SwaplineFixture.sol";
import {SwapMarket} from "../../src/core/SwapMarket.sol";
import {MarginEngine} from "../../src/core/MarginEngine.sol";
import {LPPositions} from "../../src/core/LPPositions.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {ISwapMarket} from "../../src/interfaces/ISwapMarket.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {IOracleAdapter} from "../../src/interfaces/IOracleAdapter.sol";
import {RateVAMM} from "../../src/core/RateVAMM.sol";

contract SwapMarketTest is SwaplineFixture {
    function setUp() public override {
        super.setUp();
        _seedLiquidity(market);
    }

    // ------------------------------------------------------------------ trading

    function test_payFixed_balances() public {
        _deposit(alice, market, 1_000e6);
        (int256 filled, uint256 fee) = _trade(alice, market, 10_000e6);
        assertEq(filled, 10_000e6);
        assertGt(fee, 0);
        (int256 vs, int256 fc) = market.rawBalances(alice);
        assertEq(vs, 10_000e6 * 1e18); // index 1.0
        assertLt(fc, -int256(10_000e6) * 1e18);
        assertEq(d.marginEngine.marginOf(address(market), alice), 1_000e6 - fee);
        // protocol share of fees went to the FeeCollector
        assertGt(usdg.balanceOf(address(d.feeCollector)), 0);
    }

    function test_trade_revertsBelowInitialMargin() public {
        _deposit(alice, market, 10e6);
        vm.prank(alice);
        vm.expectRevert(); // BelowInitialMargin
        market.trade(10_000e6, 1e18, block.timestamp);
    }

    function test_trade_noMargin_reverts() public {
        vm.prank(alice);
        vm.expectRevert(MarginEngine.InsufficientMargin.selector);
        market.trade(10_000e6, 1e18, block.timestamp);
    }

    function test_trade_insufficientLiquidity_reverts() public {
        _deposit(alice, market, 100_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SwapMarket.InsufficientLiquidity.selector, int256(1_000_000e6), int256(30_000e6)));
        market.trade(1_000_000e6, 1e18, block.timestamp);
    }

    function test_trade_deadline() public {
        _deposit(alice, market, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(SwapMarket.DeadlinePassed.selector);
        market.trade(1_000e6, 1e18, block.timestamp - 1);
    }

    function test_trade_zero() public {
        vm.prank(alice);
        vm.expectRevert(SwapMarket.ZeroAmount.selector);
        market.trade(0, 1e18, block.timestamp);
    }

    function test_closeEarly_locksPnl_andReleasesMargin() public {
        _deposit(alice, market, 1_000e6);
        _trade(alice, market, 10_000e6); // rate 5% -> 6%
        // bob pushes the rate up further; alice's pay-fixed is now in profit
        _deposit(bob, market, 1_000e6);
        _trade(bob, market, 10_000e6); // -> 7%
        _pass(10 days, 0.05e18);
        // alice closes by trading the opposite side
        (int256 vs,) = market.rawBalances(alice);
        int256 notional = -(vs * int256(oracle.currentIndex()) / 1e36);
        vm.prank(alice);
        market.trade(notional, 0, block.timestamp);
        (int256 vs2, int256 fc2) = market.rawBalances(alice);
        assertApproxEqAbs(vs2, 0, 1e18); // ~0 variable exposure (dust)
        assertGt(fc2, 0); // locked profit (fixed cash at maturity)
        // risk-reducing close skipped IM; she cannot withdraw locked gains before maturity, only free margin
        uint256 m = d.marginEngine.marginOf(address(market), alice);
        vm.prank(alice);
        d.marginEngine.withdraw(address(market), m - 10e6, alice);
        // after maturity she settles and withdraws everything including the gain
        vm.warp(market.maturity() + 1 hours);
        oracle.snapshot();
        int256 cash = market.settle(alice);
        assertGt(cash, 0);
        uint256 m2 = d.marginEngine.marginOf(address(market), alice);
        vm.prank(alice);
        d.marginEngine.withdraw(address(market), m2, alice);
    }

    function test_riskReducingTrade_allowedWhenBelowIM() public {
        _deposit(alice, market, 30e6);
        _trade(alice, market, 1_000e6);
        // raise IM massively; alice is now below IM but can still reduce
        IMarginEngine.RiskParams memory r = _risk();
        r.imShock = 0.5e18;
        r.mmShock = 0.01e18;
        _asTimelock();
        d.marginEngine.setRiskParams(address(market), r);
        vm.prank(alice);
        vm.expectRevert();
        market.trade(100e6, 1e18, block.timestamp);
        _trade(alice, market, -500e6);
    }

    function test_openInterestCap() public {
        SwapMarket.MarketParams memory p = _marketParams();
        p.maxOpenInterestBps = 1; // 0.01% of 10M TVL = 1k gross
        _asTimelock();
        market.setParams(p);
        _deposit(alice, market, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(SwapMarket.OpenInterestCap.selector);
        market.trade(1_001e6, 1e18, block.timestamp);
        _trade(alice, market, 1_000e6); // gross folded exposure == cap is allowed
    }

    function test_setParams_onlyAdmin_andValidation() public {
        SwapMarket.MarketParams memory p = _marketParams();
        vm.expectRevert(SwapMarket.NotAdmin.selector);
        market.setParams(p);
        p.feeRate = 0.1e18;
        _asTimelock();
        vm.expectRevert(SwapMarket.InvalidParams.selector);
        market.setParams(p);
    }

    function test_tradingClosesAtCutoff() public {
        _deposit(alice, market, 1_000e6);
        vm.warp(market.maturity() - 30 minutes);
        usdgFeed.set(1e8, block.timestamp);
        oracle.snapshot();
        vm.prank(alice);
        vm.expectRevert(SwapMarket.Expired.selector);
        market.trade(1_000e6, 1e18, block.timestamp);
    }

    function test_oracleUnhealthy_blocksNewRisk_notCloses() public {
        _deposit(alice, market, 1_000e6);
        _trade(alice, market, 5_000e6);
        vm.prank(guardian);
        oracle.flagImpaired();
        vm.prank(alice);
        vm.expectRevert(SwapMarket.OracleUnhealthy.selector);
        market.trade(1_000e6, 1e18, block.timestamp);
        _trade(alice, market, -2_000e6); // reducing is fine
        vm.prank(lp2);
        vm.expectRevert(SwapMarket.OracleUnhealthy.selector);
        market.mint(300, 700, 1e10);
    }

    function test_collateralDepeg_blocksNewRisk() public {
        _deposit(alice, market, 1_000e6);
        usdgFeed.set(0.95e8, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(SwapMarket.CollateralUnhealthy.selector);
        market.trade(1_000e6, 1e18, block.timestamp);
        _deposit(lp2, market, 1_000e6);
        vm.prank(lp2);
        vm.expectRevert(SwapMarket.CollateralUnhealthy.selector);
        market.mint(300, 700, 1e10);
    }

    function test_pause_blocksTrading_allowsDepositAndSettle() public {
        _deposit(alice, market, 1_000e6);
        _trade(alice, market, 5_000e6);
        vm.prank(guardian);
        d.marginEngine.pause();
        vm.prank(alice);
        vm.expectRevert(SwapMarket.MarketPaused.selector);
        market.trade(1_000e6, 1e18, block.timestamp);
        _deposit(alice, market, 1e6); // top-ups always allowed
        vm.prank(alice);
        vm.expectRevert();
        d.marginEngine.withdraw(address(market), 1e6, alice);
        // guardian cannot unpause; timelock can
        vm.prank(guardian);
        vm.expectRevert();
        d.marginEngine.unpause();
        _asTimelock();
        d.marginEngine.unpause();
        // per-market pause
        vm.prank(guardian);
        d.marginEngine.pauseMarket(address(market));
        vm.prank(alice);
        vm.expectRevert(SwapMarket.MarketPaused.selector);
        market.trade(1_000e6, 1e18, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(MarginEngine.MarketIsPaused.selector);
        d.marginEngine.withdraw(address(market), 1e6, alice);
        _asTimelock();
        d.marginEngine.unpauseMarket(address(market));
        _trade(alice, market, 1_000e6);
        // settlement is never blocked by pause
        vm.prank(guardian);
        d.marginEngine.pause();
        vm.warp(market.maturity() + 2 hours);
        oracle.snapshot();
        market.settle(alice);
    }

    function test_compliance_gatesWhenEnabled() public {
        _asTimelock();
        d.compliance.setEnabled(true);
        vm.prank(alice);
        vm.expectRevert(MarginEngine.NotAllowed.selector);
        d.marginEngine.deposit(address(market), alice, 1_000e6);
        address[] memory list = new address[](1);
        list[0] = alice;
        _asTimelock();
        d.compliance.setAllowlisted(list, true);
        _deposit(alice, market, 1_000e6);
        _trade(alice, market, 1_000e6);
        // bob not allowlisted: cannot trade even with margin deposited earlier by an allowed party
        vm.prank(bob);
        vm.expectRevert(SwapMarket.NotAllowed.selector);
        market.trade(1_000e6, 1e18, block.timestamp);
        vm.prank(bob);
        vm.expectRevert(SwapMarket.NotAllowed.selector);
        market.mint(300, 700, 1e10);
        // ungating an action
        _asTimelock();
        d.compliance.setGated(IComplianceRegistry.Action.Trade, false);
        assertTrue(d.compliance.isAllowed(bob, IComplianceRegistry.Action.Trade));
    }

    // ------------------------------------------------------------------ liquidity

    function test_mintBurn_collect_foldsExposureAndFees() public {
        _deposit(lp2, market, 10_000e6);
        _mint(lp2, market, 400, 600, 1e12);
        _deposit(alice, market, 1_000e6);
        _trade(alice, market, 10_000e6);
        ISwapMarket.AccountState memory s = market.accountState(lp2);
        assertLt(s.varSharesX18, 0); // lp2 took the receive-fixed side
        assertGt(s.lpFeesOwed, 0);
        uint256 mBefore = d.marginEngine.marginOf(address(market), lp2);
        vm.prank(lp2);
        market.collect(400, 600);
        assertGt(d.marginEngine.marginOf(address(market), lp2), mBefore);
        (int256 vs,) = market.rawBalances(lp2);
        assertEq(vs, s.varSharesX18);
        vm.prank(lp2);
        market.burn(400, 600, 1e12);
        assertEq(d.lpPositions.positionCount(address(market), lp2), 0);
        assertEq(d.lpPositions.liquidityOf(address(market), lp2, 400, 600), 0);
    }

    /// @dev Regression (found by the invariant suite): burning the last liquidity on a tick must read growth
    ///      before the tick is cleared, otherwise the LP is credited phantom exposure.
    function test_regression_burnEmptiedTick_noPhantomExposure() public {
        _deposit(alice, market, 1_000e6);
        _trade(alice, market, 5_000e6); // rate moves 5% -> 5.5% inside lp1's range
        _deposit(lp2, market, 1_000e6);
        _mint(lp2, market, 50, 800, 1e9); // fresh ticks (50 is new), range spans current price
        vm.prank(lp2);
        market.burn(50, 800, 1e9);
        (int256 vs, int256 fc) = market.rawBalances(lp2);
        assertEq(vs, 0);
        assertEq(fc, 0);
        // and a range fully below the price
        _mint(lp2, market, 50, 100, 1e9);
        vm.prank(lp2);
        market.burn(50, 100, 1e9);
        (vs, fc) = market.rawBalances(lp2);
        assertEq(vs, 0);
        assertEq(fc, 0);
    }

    function test_mint_requiresMargin() public {
        vm.prank(lp2);
        vm.expectRevert(); // BelowInitialMargin (no margin, worst case exposure 20k)
        market.mint(400, 600, 1e12);
    }

    function test_mint_zero_andPositionsLimit() public {
        vm.prank(lp2);
        vm.expectRevert(SwapMarket.ZeroAmount.selector);
        market.mint(400, 600, 0);
        vm.prank(lp2);
        vm.expectRevert(SwapMarket.ZeroAmount.selector);
        market.burn(400, 600, 0);
        _deposit(lp2, market, 100_000e6);
        for (int24 i; i < 8; ++i) {
            _mint(lp2, market, 100 + i * 10, 200 + i * 10, 1e9);
        }
        vm.prank(lp2);
        vm.expectRevert(LPPositions.TooManyPositions.selector);
        market.mint(500, 600, 1e9);
        // burning liquidity that does not exist underflows the tick book first
        vm.prank(lp2);
        vm.expectRevert(RateVAMM.LiquidityUnderflow.selector);
        market.burn(900, 1000, 1e9);
        // shared range: carol cannot burn lp2's liquidity
        _deposit(carol, market, 100_000e6);
        vm.prank(carol);
        vm.expectRevert(LPPositions.PositionNotFound.selector);
        market.burn(100, 200, 1e9);
        _mint(carol, market, 100, 200, 1e9);
        vm.prank(carol);
        vm.expectRevert(LPPositions.InsufficientLiquidity.selector);
        market.burn(100, 200, 2e9);
    }

    function test_lpPositions_onlyMarketAndFactory() public {
        RateVAMM.GrowthInside memory g = market.vammContract().growthInside(0, 10);
        vm.expectRevert(LPPositions.OnlyMarket.selector);
        d.lpPositions.update(alice, 0, 10, 1, g);
        vm.expectRevert();
        d.lpPositions.registerMarket(alice);
    }

    // ------------------------------------------------------------------ settlement

    function test_settle_requiresMaturity_andOnce() public {
        _deposit(alice, market, 1_000e6);
        _trade(alice, market, 5_000e6);
        vm.expectRevert(SwapMarket.NotMatured.selector);
        market.settle(alice);
        vm.warp(market.maturity() + 2 hours);
        market.settle(alice); // snapshots the oracle itself
        vm.expectRevert(SwapMarket.AlreadySettled.selector);
        market.settle(alice);
        assertTrue(market.settled(alice));
        assertGt(market.settlementIndex(), 0);
    }

    function test_settle_pendingWhenOracleCannotObserve() public {
        _deposit(alice, market, 1_000e6);
        _trade(alice, market, 5_000e6);
        // snapshot just before maturity, then try to settle within minInterval after maturity
        vm.warp(market.maturity() - 10 minutes);
        oracle.snapshot();
        vm.warp(market.maturity() + 1 minutes);
        vm.expectRevert(SwapMarket.SettlementPending.selector);
        market.settle(alice);
        vm.warp(market.maturity() + 1 hours);
        market.settle(alice);
    }

    function test_withdrawAfterMaturity_requiresSettlement() public {
        _deposit(alice, market, 1_000e6);
        _trade(alice, market, 5_000e6);
        vm.warp(market.maturity() + 2 hours);
        vm.prank(alice);
        vm.expectRevert(MarginEngine.SettlementRequired.selector);
        d.marginEngine.withdraw(address(market), 1e6, alice);
        market.settle(alice);
        vm.prank(alice);
        d.marginEngine.withdraw(address(market), 1e6, alice);
    }

    function test_settlement_floatingAboveFixed_payFixedWins() public {
        _deposit(alice, market, 1_000e6);
        _trade(alice, market, 10_000e6); // pays ~5.5% fixed
        for (uint256 i; i < 92; ++i) {
            _pass(1 days, 0.09e18); // floating realises ~9%
        }
        int256 cash = market.settle(alice);
        int256 lpCash = market.settle(lp1);
        // ~ 10k * (9.1% - 5.5%) * 0.249y ~ +89
        assertGt(cash, 80e6);
        assertLt(cash, 100e6);
        assertApproxEqAbs(cash + lpCash, 0, 2);
    }

    function test_settlement_lossCoveredByInsurance_badDebt() public {
        _deposit(alice, market, 40e6);
        _trade(alice, market, 1_000e6);
        // floating collapses: the source loses value (impairment) -> pay-fixed loses notional
        uint256 ta = yv.totalAssets();
        vm.prank(address(yv));
        usdg.transfer(address(0xdead), ta / 10); // -10% share price
        vm.warp(block.timestamp + 1 days);
        oracle.snapshot();
        assertTrue(oracle.impaired());
        // fund insurance partially
        vm.prank(carol);
        usdg.approve(address(d.marginEngine), type(uint256).max);
        vm.prank(carol);
        d.marginEngine.fundInsurance(10e6);
        vm.warp(market.maturity() + 2 hours);
        int256 cash = market.settle(alice);
        assertLt(cash, -40e6);
        assertEq(d.marginEngine.marginOf(address(market), alice), 0);
        assertEq(d.marginEngine.insuranceFund(), 0);
        assertGt(d.marginEngine.deficit(), 0);
    }

    // ------------------------------------------------------------------ margin engine

    function test_withdraw_respectsIM() public {
        _deposit(alice, market, 100e6);
        _trade(alice, market, 5_000e6);
        IMarginEngine.Health memory h = d.marginEngine.health(address(market), alice);
        assertGt(h.initialRequirement, 0);
        vm.prank(alice);
        vm.expectRevert();
        d.marginEngine.withdraw(address(market), 90e6, alice);
        vm.prank(alice);
        d.marginEngine.withdraw(address(market), 10e6, alice);
        vm.prank(alice);
        vm.expectRevert(MarginEngine.InsufficientMargin.selector);
        d.marginEngine.withdraw(address(market), 1_000e6, alice);
        vm.prank(alice);
        vm.expectRevert(MarginEngine.ZeroAmount.selector);
        d.marginEngine.withdraw(address(market), 0, alice);
    }

    function test_deposit_guards() public {
        vm.prank(alice);
        vm.expectRevert(MarginEngine.ZeroAmount.selector);
        d.marginEngine.deposit(address(market), alice, 0);
        vm.prank(alice);
        vm.expectRevert(MarginEngine.UnknownMarket.selector);
        d.marginEngine.deposit(address(0x1234), alice, 1);
        vm.prank(alice);
        vm.expectRevert(MarginEngine.UnknownMarket.selector);
        d.marginEngine.withdraw(address(0x1234), 1, alice);
    }

    function test_marketHooks_onlyMarket() public {
        vm.expectRevert(MarginEngine.OnlyMarket.selector);
        d.marginEngine.chargeFee(alice, 1, 0);
        vm.expectRevert(MarginEngine.OnlyMarket.selector);
        d.marginEngine.creditLpFee(alice, 1);
        vm.expectRevert(MarginEngine.OnlyMarket.selector);
        d.marginEngine.checkInitialMargin(alice);
        vm.expectRevert(MarginEngine.OnlyMarket.selector);
        d.marginEngine.settleAccount(alice, 1);
        vm.expectRevert(MarginEngine.OnlyMarket.selector);
        d.marginEngine.payLiquidationReward(alice, bob, 1);
        vm.expectRevert(MarginEngine.UnknownMarket.selector);
        d.marginEngine.poke(address(0x1));
        vm.expectRevert(MarginEngine.UnknownMarket.selector);
        d.marginEngine.pokeIfDue(address(0x1));
    }

    function test_dailyMark_isTwap() public {
        _deposit(alice, market, 10_000e6);
        uint256 t0 = block.timestamp;
        _trade(alice, market, 10_000e6); // 5% -> 6%
        MarginEngine.MarketInfo memory info = d.marginEngine.marketInfo(address(market));
        assertEq(info.markRate, 0.05e18);
        vm.warp(t0 + 12 hours);
        _trade(alice, market, 10_000e6); // 6% -> 7% (mark not due yet)
        vm.warp(t0 + 1 days);
        d.marginEngine.poke(address(market));
        info = d.marginEngine.marketInfo(address(market));
        // TWAP over the day: half at ~6%, half at ~7%
        assertApproxEqRel(info.markRate, 0.065e18, 0.001e18);
        assertEq(info.markTime, block.timestamp);
    }

    function test_adminSetters() public {
        IMarginEngine.RiskParams memory r = _risk();
        vm.expectRevert();
        d.marginEngine.setRiskParams(address(market), r);
        _asTimelock();
        vm.expectRevert(MarginEngine.UnknownMarket.selector);
        d.marginEngine.setRiskParams(address(0x1), r);
        r.mmShock = 0;
        _asTimelock();
        vm.expectRevert(MarginEngine.InvalidParams.selector);
        d.marginEngine.setRiskParams(address(market), r);
        vm.startPrank(address(d.timelock));
        d.marginEngine.setOracleAdapter(d.oracleAdapter);
        d.marginEngine.setCompliance(d.compliance);
        d.marginEngine.setFeeCollector(address(0));
        vm.stopPrank();
        // with no fee collector, protocol fees go to insurance
        _deposit(alice, market, 1_000e6);
        _trade(alice, market, 1_000e6);
        assertGt(d.marginEngine.insuranceFund(), 0);
        uint256 ins = d.marginEngine.insuranceFund();
        _asTimelock();
        d.marginEngine.withdrawInsurance(treasury, ins);
        _asTimelock();
        vm.expectRevert(MarginEngine.InsufficientMargin.selector);
        d.marginEngine.withdrawInsurance(treasury, 1);
        vm.expectRevert(MarginEngine.ZeroAmount.selector);
        d.marginEngine.fundInsurance(0);
    }

    function test_collateralHealthy_noAdapter() public {
        _asTimelock();
        d.marginEngine.setOracleAdapter(IOracleAdapter(address(0)));
        assertTrue(d.marginEngine.collateralHealthy());
    }

    function test_constructorGuards() public {
        vm.expectRevert(MarginEngine.InvalidParams.selector);
        new MarginEngine(usdg, address(0), guardian);
    }
}

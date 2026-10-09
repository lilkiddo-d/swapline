// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {RateVAMM} from "../../src/core/RateVAMM.sol";

/// @dev Drives the vAMM directly (this test contract acts as the market).
contract RateVAMMTest is Test {
    RateVAMM v;

    function setUp() public {
        vm.warp(1_790_000_000);
        v = RateVAMM(Clones.clone(address(new RateVAMM())));
        v.initialize(address(this), 10, 0.05e18);
    }

    function _p(int256 amount, uint256 limit) internal pure returns (RateVAMM.SwapParams memory) {
        return RateVAMM.SwapParams({
            amount: amount,
            rateLimit: limit,
            index: 1e18,
            tau: 0.25e18,
            feeRate: 0.004e18,
            protocolFeeBps: 2_500
        });
    }

    function test_initialize_guards() public {
        RateVAMM impl = new RateVAMM();
        vm.expectRevert();
        impl.initialize(address(this), 10, 0.05e18); // implementation is locked
        RateVAMM c = RateVAMM(Clones.clone(address(impl)));
        vm.expectRevert(RateVAMM.InvalidSpacing.selector);
        c.initialize(address(this), 7, 0.05e18);
        vm.expectRevert(RateVAMM.InvalidSpacing.selector);
        c.initialize(address(this), 5, 0.05e18);
        vm.expectRevert(RateVAMM.InvalidRateLimit.selector);
        c.initialize(address(this), 10, 1.5e18);
        vm.expectRevert();
        v.initialize(address(this), 10, 0.05e18); // already initialised
        assertEq(v.tick(), 500);
    }

    function test_onlyMarket() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(RateVAMM.OnlyMarket.selector);
        v.swap(_p(1, 1e18));
        vm.prank(address(0xBEEF));
        vm.expectRevert(RateVAMM.OnlyMarket.selector);
        v.updateLiquidity(0, 100, 1);
    }

    function test_invalidTicks() public {
        vm.expectRevert(RateVAMM.InvalidTicks.selector);
        v.updateLiquidity(100, 100, 1);
        vm.expectRevert(RateVAMM.InvalidTicks.selector);
        v.updateLiquidity(-10, 100, 1);
        vm.expectRevert(RateVAMM.InvalidTicks.selector);
        v.updateLiquidity(0, 10_010, 1);
        vm.expectRevert(RateVAMM.InvalidTicks.selector);
        v.updateLiquidity(5, 100, 1);
    }

    function test_swapUp_linearFill() public {
        v.updateLiquidity(400, 600, 1e12); // L=1e12 over [4%,6%)
        assertEq(v.liquidity(), 1e12);
        RateVAMM.SwapResult memory r = v.swap(_p(5_000e6, 1e18)); // 5k => +0.5%
        assertEq(r.filled, 5_000e6);
        assertApproxEqAbs(v.rate(), 0.055e18, 2);
        assertEq(v.tick(), 550);
        // fixed leg: notional * (1 + avg * tau), avg = 5.25%
        int256 expectedFixed = -int256(5_000e6 * 1e18 + (5_000e6 * uint256(0.0525e18) * 0.25e18) / 1e18);
        assertApproxEqRel(r.traderFixedCashX18, expectedFixed, 1e9);
        assertEq(r.traderVarSharesX18, int256(5_000e6) * 1e18);
        // fee = notional * feeRate * tau
        assertEq(r.feeX18, 5_000e6 * 1e18 * 0.004e18 * 0.25e18 / 1e36);
        assertEq(r.protocolFeeX18, r.feeX18 / 4);
    }

    function test_swapDown_linearFill() public {
        v.updateLiquidity(400, 600, 1e12);
        RateVAMM.SwapResult memory r = v.swap(_p(-5_000e6, 0));
        assertEq(r.filled, -5_000e6);
        assertApproxEqAbs(v.rate(), 0.045e18, 2);
        assertLt(r.traderVarSharesX18, 0);
        assertGt(r.traderFixedCashX18, 0);
    }

    function test_rateLimit_stopsSwap() public {
        v.updateLiquidity(400, 600, 1e12);
        RateVAMM.SwapResult memory r = v.swap(_p(10_000e6, 0.052e18));
        assertEq(v.rate(), 0.052e18);
        assertEq(r.filled, 2_000e6);
        vm.expectRevert(RateVAMM.InvalidRateLimit.selector);
        v.swap(_p(1e6, 0.05e18)); // limit below current for an up-swap
        vm.expectRevert(RateVAMM.InvalidRateLimit.selector);
        v.swap(_p(-1e6, 0.06e18));
        vm.expectRevert(RateVAMM.InvalidRateLimit.selector);
        v.swap(_p(1e6, 2e18));
        vm.expectRevert(RateVAMM.ZeroAmount.selector);
        v.swap(_p(0, 1e18));
    }

    function test_crossTicks_multipleRanges() public {
        v.updateLiquidity(400, 600, 1e12);
        v.updateLiquidity(550, 700, 2e12);
        // from 5%: [5%,5.5%) L=1e12 cap 5k; [5.5%,6%) L=3e12 cap 15k; [6%,7%) L=2e12 cap 20k
        RateVAMM.SwapResult memory r = v.swap(_p(30_000e6, 1e18));
        assertEq(r.filled, 30_000e6);
        assertEq(r.crossings, 2);
        assertApproxEqAbs(v.rate(), 0.065e18, 2);
        assertEq(v.liquidity(), 2e12);
        // back down: 10k (L=2e12) + 15k (L=3e12) + 5k + 5k (L=1e12) = 35k to reach 4.5%
        r = v.swap(_p(-35_000e6, 0));
        assertEq(r.filled, -35_000e6);
        assertApproxEqAbs(v.rate(), 0.045e18, 3);
        assertEq(v.liquidity(), 1e12);
    }

    function test_rangeExhaustion_partialFill() public {
        v.updateLiquidity(400, 600, 1e12); // 10k above 5%
        RateVAMM.SwapResult memory r = v.swap(_p(50_000e6, 1e18));
        assertEq(r.filled, 10_000e6);
        assertEq(v.rate(), 0.06e18);
        assertEq(v.liquidity(), 0);
        // nothing more above
        r = v.swap(_p(1e6, 1e18));
        assertEq(r.filled, 0);
    }

    function test_jumpAcrossEmptyGap() public {
        v.updateLiquidity(700, 800, 1e12); // rate 5% sits in an empty region
        RateVAMM.SwapResult memory r = v.swap(_p(5_000e6, 1e18));
        assertEq(r.filled, 5_000e6);
        assertApproxEqAbs(v.rate(), 0.075e18, 2);
        // down from 7.5% jumps below 7% would exhaust (no liquidity below 7%)
        r = v.swap(_p(-20_000e6, 0));
        assertEq(r.filled, -5_000e6);
        assertEq(v.rate(), 0.07e18);
    }

    function test_growthInside_and_feeGrowth() public {
        v.updateLiquidity(400, 600, 1e12);
        v.swap(_p(5_000e6, 1e18));
        RateVAMM.GrowthInside memory g = v.growthInside(400, 600);
        // LP collective exposure = -trader exposure
        assertApproxEqAbs(int256(g.var_) * 1e12 / 1e18, -int256(5_000e6) * 1e18, 1e12);
        assertGt(g.fixed_, 0);
        assertGt(g.fee, 0);
        // a range not touched by price has zero growth
        RateVAMM.GrowthInside memory out = v.growthInside(700, 800);
        assertEq(out.fee, 0);
        assertEq(out.var_, 0);
    }

    function test_removeLiquidity_clearsTicks() public {
        v.updateLiquidity(400, 600, 1e12);
        (uint128 gross,,,,) = v.ticks(400);
        assertEq(gross, 1e12);
        v.updateLiquidity(400, 600, -1e12);
        (gross,,,,) = v.ticks(400);
        assertEq(gross, 0);
        assertEq(v.liquidity(), 0);
        vm.expectRevert(RateVAMM.LiquidityUnderflow.selector);
        v.updateLiquidity(400, 600, -1);
    }

    function test_maxCrossings_bounded() public {
        // 80 one-spacing ranges above the price
        for (int24 t = 500; t < 1300; t += 10) {
            v.updateLiquidity(t, t + 10, 1e9);
        }
        RateVAMM.SwapResult memory r = v.swap(_p(1_000_000e6, 1e18));
        assertEq(r.crossings, v.MAX_CROSSINGS());
        assertLt(r.filled, 1_000_000e6);
    }

    function test_observe_accumulates() public {
        (uint256 c0,) = v.observe();
        vm.warp(block.timestamp + 100);
        (uint256 c1, uint256 ts) = v.observe();
        assertEq(c1 - c0, 0.05e18 * 100);
        assertEq(ts, block.timestamp);
        v.updateLiquidity(400, 600, 1e12); // checkpoints the accumulator
        assertEq(v.rateCumulative(), c1);
    }

    function test_swapDown_toZeroRate() public {
        v.updateLiquidity(0, 600, 1e12);
        RateVAMM.SwapResult memory r = v.swap(_p(-100_000e6, 0));
        assertEq(r.filled, -50_000e6);
        assertEq(v.rate(), 0);
        assertEq(v.tick(), -1);
        // and back up from below tick 0
        r = v.swap(_p(1_000e6, 1e18));
        assertEq(r.filled, 1_000e6);
    }

    function testFuzz_roundTripNeverProfitsTrader(uint256 amt) public {
        amt = bound(amt, 1e6, 9_000e6);
        v.updateLiquidity(400, 600, 1e12);
        RateVAMM.SwapResult memory a = v.swap(_p(int256(amt), 1e18));
        RateVAMM.SwapResult memory b = v.swap(_p(-a.filled, 0));
        assertEq(b.filled, -a.filled);
        // trader's net variable ~0 and net fixed cash <= 0 (rounding always against the trader)
        assertEq(a.traderVarSharesX18 + b.traderVarSharesX18, 0);
        assertLe(a.traderFixedCashX18 + b.traderFixedCashX18, 0);
    }

    /// @dev Bitmap words hold 256 compressed ticks (2560 ticks at spacing 10): exercise searches across words.
    function test_crossWordSearch_bothDirections() public {
        v.updateLiquidity(100, 200, 1e12); // word 0
        v.updateLiquidity(5_000, 5_100, 1e12); // word 1 (compressed 500)
        // 5% sits in the gap: going down must walk from word 0's upper part to tick 200; going up must find 5000
        RateVAMM.SwapResult memory r = v.swap(_p(-1_000e6, 0));
        assertEq(r.filled, -1_000e6);
        assertApproxEqAbs(v.rate(), 0.019e18, 2);
        r = v.swap(_p(2_000e6, 1e18)); // back up through the empty gap into the 50% range
        assertEq(r.filled, 2_000e6);
        assertGt(v.rate(), 0.5e18);
        // all the way down from word 1 to word 0
        r = v.swap(_p(-3_000e6, 0));
        assertEq(r.filled, -2_000e6 - 1_000e6);
    }
}

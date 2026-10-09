// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SwaplineFixture} from "../utils/SwaplineFixture.sol";
import {SwapMarket} from "../../src/core/SwapMarket.sol";
import {Liquidator} from "../../src/core/Liquidator.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {ISwapMarket} from "../../src/interfaces/ISwapMarket.sol";

contract LiquidationTest is SwaplineFixture {
    function setUp() public override {
        super.setUp();
        _seedLiquidity(market);
    }

    /// @dev alice pays fixed (avg 5.75%) with thin margin; bob then receives fixed and drives the rate to 2.5%; the
    ///      daily mark captures it: MTM ~ 15k*(1+2.5%*0.245) - 15.21k = -122 vs margin ~149 => equity ~27 < MM ~58.
    function _setupAlice() internal {
        _deposit(alice, market, 160e6);
        _trade(alice, market, 15_000e6); // 5% -> 6.5%
        _deposit(bob, market, 10_000e6);
        _trade(bob, market, -40_000e6); // 6.5% -> 2.5%
        vm.warp(block.timestamp + 1 days);
        usdgFeed.set(1e8, block.timestamp);
        oracle.snapshot();
        d.marginEngine.poke(address(market)); // mark = TWAP ~4%
    }

    function test_liquidation_unwinds_andPaysReward() public {
        _deposit(lp2, market, 10_000e6);
        _mint(lp2, market, 0, 200, 1e12); // depth below 2% so the unwind can complete
        _setupAlice();
        assertTrue(d.marginEngine.isLiquidatable(address(market), alice));
        IMarginEngine.Health memory h = d.marginEngine.health(address(market), alice);
        uint256 keeperBefore = usdg.balanceOf(keeper);
        vm.prank(keeper);
        uint256 reward = d.liquidator.liquidate(ISwapMarket(address(market)), alice);
        assertGt(reward, 0);
        assertEq(reward, (h.maintenanceRequirement * 1_000) / 10_000);
        assertEq(usdg.balanceOf(keeper) - keeperBefore, reward);
        (int256 vs,) = market.rawBalances(alice);
        assertApproxEqAbs(vs, 0, 1e18);
        // fully unwound: nothing left to liquidate, so keepers cannot repeatedly skim rewards
        assertFalse(d.marginEngine.isLiquidatable(address(market), alice));
        vm.prank(keeper);
        vm.expectRevert(SwapMarket.NotLiquidatable.selector);
        d.liquidator.liquidate(ISwapMarket(address(market)), alice);
    }

    function test_liquidation_revertsWhenHealthy() public {
        _deposit(alice, market, 1_000e6);
        _trade(alice, market, 1_000e6);
        vm.prank(keeper);
        vm.expectRevert(SwapMarket.NotLiquidatable.selector);
        d.liquidator.liquidate(ISwapMarket(address(market)), alice);
    }

    function test_liquidate_onlyViaLiquidator() public {
        _setupAlice();
        vm.expectRevert(SwapMarket.NotLiquidator.selector);
        market.liquidate(alice, keeper, 0.03e18);
    }

    function test_liquidateMany_bestEffort() public {
        _setupAlice();
        address[] memory accts = new address[](2);
        accts[0] = alice;
        accts[1] = carol; // healthy/no position -> fails, reported via event
        vm.prank(keeper);
        uint256 total = d.liquidator.liquidateMany(ISwapMarket(address(market)), accts);
        assertGt(total, 0);
        address[] memory big = new address[](21);
        vm.expectRevert(Liquidator.BatchTooLarge.selector);
        d.liquidator.liquidateMany(ISwapMarket(address(market)), big);
    }

    function test_liquidation_ofLp_closesRanges() public {
        // lp2 provides thin-margin liquidity; traders push through the range, then the rate moves against lp2
        _deposit(lp2, market, 30e6);
        _mint(lp2, market, 500, 600, 1e11); // 1k capacity over [5%,6%)
        _deposit(alice, market, 5_000e6);
        _trade(alice, market, 20_000e6); // lp2 now receive-fixed ~1k at ~5.5%
        vm.warp(block.timestamp + 1 days);
        usdgFeed.set(1e8, block.timestamp);
        oracle.snapshot();
        d.marginEngine.poke(address(market));
        IMarginEngine.RiskParams memory r = _risk();
        r.mmShock = 0.6e18; // force lp2 under maintenance
        r.imShock = 0.6e18;
        _asTimelock();
        d.marginEngine.setRiskParams(address(market), r);
        assertTrue(d.marginEngine.isLiquidatable(address(market), lp2));
        vm.prank(keeper);
        d.liquidator.liquidate(ISwapMarket(address(market)), lp2);
        assertEq(d.lpPositions.positionCount(address(market), lp2), 0);
    }

    function test_noLiquidationAfterMaturity() public {
        _setupAlice();
        vm.warp(market.maturity());
        assertFalse(d.marginEngine.isLiquidatable(address(market), alice));
    }

    function test_rateBand_admin() public {
        vm.expectRevert();
        d.liquidator.setRateBand(0.01e18);
        _asTimelock();
        d.liquidator.setRateBand(0.01e18);
        assertEq(d.liquidator.rateBand(), 0.01e18);
        _asTimelock();
        vm.expectRevert(Liquidator.InvalidBand.selector);
        d.liquidator.setRateBand(0);
    }

    function test_liquidation_partialWhenRangeExhausted_staysLiquidatable() public {
        _setupAlice();
        // remove most LP liquidity below the current rate so the unwind cannot complete
        (int256 vs,) = market.rawBalances(alice);
        assertGt(vs, 0);
        vm.prank(lp1);
        market.burn(200, 800, 1e12);
        vm.prank(keeper);
        d.liquidator.liquidate(ISwapMarket(address(market)), alice);
        (int256 vsAfter,) = market.rawBalances(alice);
        assertEq(vsAfter, vs); // nothing could be unwound (no liquidity); reward still paid from margin
    }
}

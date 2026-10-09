// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SwaplineFixture} from "../utils/SwaplineFixture.sol";
import {console2} from "forge-std/console2.sol";

contract SmokeTest is SwaplineFixture {
    function test_lifecycle() public {
        _seedLiquidity(market);
        _deposit(alice, market, 10_000e6);
        _deposit(bob, market, 10_000e6);

        uint256 r0 = market.currentRate();
        (int256 filled, uint256 fee) = _trade(alice, market, 20_000e6); // pay fixed 20k
        console2.log("filled", filled);
        console2.log("fee", fee);
        console2.log("rate before/after", r0, market.currentRate());
        assertEq(filled, 20_000e6);
        assertGt(market.currentRate(), r0);

        _trade(bob, market, -15_000e6);
        console2.log("rate after bob", market.currentRate());

        // floating accrues at 6% for the whole term
        uint256 steps = 91;
        for (uint256 i; i < steps; ++i) {
            _pass(1 days, 0.06e18);
        }
        assertGe(block.timestamp, market.maturity());

        uint256 balBefore = usdg.balanceOf(address(d.marginEngine));
        int256 ca = market.settle(alice);
        int256 cb = market.settle(bob);
        int256 cl = market.settle(lp1);
        console2.log("alice cash", ca);
        console2.log("bob cash", cb);
        console2.log("lp cash", cl);
        int256 sum = ca + cb + cl;
        assertLe(sum, 0);
        assertGe(sum, -3);
        assertEq(usdg.balanceOf(address(d.marginEngine)), balBefore);
    }
}

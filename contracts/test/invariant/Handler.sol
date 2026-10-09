// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SwapMarket} from "../../src/core/SwapMarket.sol";
import {MarginEngine} from "../../src/core/MarginEngine.sol";
import {RateOracle} from "../../src/oracle/RateOracle.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";
import {ISwapMarket} from "../../src/interfaces/ISwapMarket.sol";
import {Liquidator} from "../../src/core/Liquidator.sol";
import {LPPositions} from "../../src/core/LPPositions.sol";
import {MockERC20, MockYieldVault} from "../utils/Mocks.sol";

/// @dev Random-action driver for the invariant suite. Tracks ghost variables used by the invariants.
contract Handler is Test {
    SwapMarket public market;
    MarginEngine public me;
    RateOracle public oracle;
    Liquidator public liquidator;
    MockERC20 public usdg;
    MockYieldVault public yv;

    address[] public actors;
    mapping(address => bool) public touched;

    // ghosts
    uint256 public imViolations; // successful risk-increasing trades that left the account below IM
    int256 public totalSettled;
    uint256 public settledCount;
    uint256 public calls;

    constructor(SwapMarket m, MarginEngine e, RateOracle o, Liquidator l, MockERC20 u, MockYieldVault y, address[] memory a)
    {
        market = m;
        me = e;
        oracle = o;
        liquidator = l;
        usdg = u;
        yv = y;
        actors = a;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _beforeMaturity() internal view returns (bool) {
        return block.timestamp + 2 hours < market.maturity();
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        calls++;
        address a = _actor(actorSeed);
        amount = bound(amount, 1e6, 50_000e6);
        vm.prank(a);
        me.deposit(address(market), a, amount);
    }

    function trade(uint256 actorSeed, int256 notional) external {
        calls++;
        if (!_beforeMaturity()) return;
        address a = _actor(actorSeed);
        notional = bound(notional, -40_000e6, 40_000e6);
        if (notional == 0) return;
        (int256 vsBefore,) = market.rawBalances(a);
        vm.prank(a);
        try market.trade(notional, notional > 0 ? 1e18 : 0, block.timestamp) {
            touched[a] = true;
            (int256 vsAfter,) = market.rawBalances(a);
            bool increasing = _abs(vsAfter) > _abs(vsBefore) || (vsBefore > 0 && vsAfter < 0) || (vsBefore < 0 && vsAfter > 0);
            if (increasing) {
                IMarginEngine.Health memory h = me.initialHealth(address(market), a);
                if (h.equity < int256(h.initialRequirement)) imViolations++;
            }
        } catch {}
    }

    function mint(uint256 actorSeed, uint256 lowerSeed, uint256 width, uint128 liq) external {
        calls++;
        if (!_beforeMaturity()) return;
        address a = _actor(actorSeed);
        int24 lower = int24(int256(bound(lowerSeed, 0, 90))) * 10;
        int24 upper = lower + int24(int256(bound(width, 1, 30))) * 10;
        liq = uint128(bound(liq, 1e9, 5e12));
        vm.prank(a);
        try market.mint(lower, upper, liq) {
            touched[a] = true;
            IMarginEngine.Health memory h = me.initialHealth(address(market), a);
            if (h.equity < int256(h.initialRequirement)) imViolations++;
        } catch {}
    }

    function burnAll(uint256 actorSeed) external {
        calls++;
        address a = _actor(actorSeed);
        LPPositions.Position[] memory list = market.lpPositions().positionsOf(address(market), a);
        if (list.length == 0) return;
        vm.prank(a);
        try market.burn(list[0].lower, list[0].upper, list[0].liquidity) {} catch {}
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        calls++;
        address a = _actor(actorSeed);
        uint256 m = me.marginOf(address(market), a);
        if (m == 0) return;
        amount = bound(amount, 1, m);
        vm.prank(a);
        try me.withdraw(address(market), amount, a) {} catch {}
    }

    /// @dev Advance time with yield in [0%, 20%] APR (sometimes a donation spike), then snapshot + mark.
    function passTime(uint256 dtSeed, uint256 aprSeed) external {
        calls++;
        uint256 dt = bound(dtSeed, 1 hours, 5 days);
        uint256 apr = bound(aprSeed, 0, 0.2e18);
        uint256 ta = yv.totalAssets();
        vm.warp(block.timestamp + dt);
        usdg.mint(address(yv), (ta * apr * dt) / (365 days * 1e18));
        if (aprSeed % 17 == 0) usdg.mint(address(yv), ta / 50); // 2% donation spike
        oracle.snapshot();
        me.poke(address(market));
    }

    function liquidate(uint256 actorSeed) external {
        calls++;
        address a = _actor(actorSeed);
        try liquidator.liquidate(ISwapMarket(address(market)), a) {} catch {}
    }

    function settleAll() external {
        calls++;
        if (block.timestamp < market.maturity()) return;
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            if (market.settled(a)) continue;
            try market.settle(a) returns (int256 c) {
                totalSettled += c;
                settledCount++;
            } catch {}
        }
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}

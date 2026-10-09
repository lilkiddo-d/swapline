// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SwaplineDeployer} from "../../script/SwaplineDeployer.sol";
import {SwapMarket} from "../../src/core/SwapMarket.sol";
import {RateOracle} from "../../src/oracle/RateOracle.sol";
import {FixedRateVault} from "../../src/vault/FixedRateVault.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";

/// @notice Fork tests against Robinhood Chain mainnet with the REAL token, vault, feed and oracle addresses from
///         config/robinhood.json. Run with:  RH_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --mp test/fork
///         Skipped automatically when RH_RPC_URL is not set.
contract MainnetForkTest is Test, SwaplineDeployer {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant USDG_USD = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant STEAK = 0xBeEff033F34C046626B8D0A041844C5d1A5409dd;
    address constant SPARK = 0xde770c84FE66E063336b31737cFE9790f18c4087;
    address constant SYRUP = 0x40858070814a57FdF33a613ae84fE0a8b4a874f7;
    address constant SYRUP_FEED = 0xDd194C66aDcb422F188a04434e4824D70c151cF0;

    bool forked;
    Deployment dep;
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    address saver = makeAddr("saver");

    function setUp() public {
        string memory rpc = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        Deployment memory dm = _deploySwapline(_cfg());
        _store(dm);
        deal(USDG, lp, 5_000_000e6);
        deal(USDG, trader, 1_000_000e6);
        deal(USDG, saver, 1_000_000e6);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _cfg() internal view returns (Config memory c) {
        c.deployer = address(this);
        c.stablecoin = USDG;
        c.stablecoinUsdFeed = USDG_USD;
        c.stablecoinHeartbeat = 93_600;
        c.guardian = address(this);
        c.proposer = address(this);
        c.treasury = address(this);
        c.timelockDelay = 48 hours;
        c.maturityDays = new uint256[](3);
        c.maturityDays[0] = 30;
        c.maturityDays[1] = 91;
        c.maturityDays[2] = 182;
        c.sources = new SourceConfig[](3);
        c.sources[0] = SourceConfig("steakUSDG", SourceKind.ERC4626, STEAK, STEAK, 0, 0.3e18, 0.04e18, true, "Steakhouse USDG");
        c.sources[1] = SourceConfig("spUSDG", SourceKind.Spark, SPARK, SPARK, 0, 0.3e18, 0.035e18, true, "Spark Savings USDG");
        c.sources[2] = SourceConfig("syrupUSDG", SourceKind.Chainlink, SYRUP_FEED, SYRUP, 172_800, 0.3e18, 0.06e18, false, "Maple syrupUSDG");
    }

    function _store(Deployment memory dm) internal {
        dep.timelock = dm.timelock;
        dep.compliance = dm.compliance;
        dep.oracleAdapter = dm.oracleAdapter;
        dep.marginEngine = dm.marginEngine;
        dep.lpPositions = dm.lpPositions;
        dep.factory = dm.factory;
        dep.liquidator = dm.liquidator;
        dep.feeCollector = dm.feeCollector;
        dep.projectTokenHooks = dm.projectTokenHooks;
        dep.rateSources = dm.rateSources;
        dep.oracles = dm.oracles;
        for (uint256 i; i < dm.markets.length; ++i) dep.markets.push(dm.markets[i]);
    }

    function test_fork_realAddresses() public onlyFork {
        assertEq(IAggregatorV3(USDG_USD).decimals(), 8);
        assertEq(IERC4626(STEAK).asset(), USDG);
        assertEq(IERC4626(SPARK).asset(), USDG);
        assertGt(IERC20(SYRUP).totalSupply(), 0);
        assertTrue(dep.oracleAdapter.isCollateralHealthy(USDG));
        assertTrue(dep.marginEngine.collateralHealthy());
        for (uint256 i; i < 3; ++i) {
            RateOracle o = RateOracle(dep.oracles[i]);
            assertTrue(o.isHealthy());
            uint256 idx = o.currentIndex();
            assertGt(idx, 1e18); // all three sources have accrued yield since launch
            assertLt(idx, 1.5e18);
        }
    }

    /// @dev Floating rates derived purely from on-chain index growth over a simulated day are in a sane range.
    function test_fork_floatingRatesFromIndexGrowth() public onlyFork {
        uint256 i0 = RateOracle(dep.oracles[1]).currentIndex();
        vm.warp(block.timestamp + 1 days);
        assertTrue(RateOracle(dep.oracles[1]).snapshot()); // Spark chi accrues with time
        uint256 i1 = RateOracle(dep.oracles[1]).currentIndex();
        assertGt(i1, i0);
        int256 r = RateOracle(dep.oracles[1]).realizedRate(block.timestamp - 1 days, block.timestamp);
        assertGt(r, 0.001e18);
        assertLt(r, 0.25e18);
        // steakUSDG (Morpho Vault V2) accrues in view as time passes too
        assertTrue(RateOracle(dep.oracles[0]).snapshot());
        assertGe(RateOracle(dep.oracles[0]).currentIndex(), 1e18);
    }

    function test_fork_fullTradeLifecycle_steakUSDG() public onlyFork {
        SwapMarket m = SwapMarket(dep.markets[0].market); // steakUSDG 30D
        vm.startPrank(lp);
        IERC20(USDG).approve(address(dep.marginEngine), type(uint256).max);
        dep.marginEngine.deposit(address(m), lp, 200_000e6);
        m.mint(200, 800, 2e12); // 2%..8%
        vm.stopPrank();

        vm.startPrank(trader);
        IERC20(USDG).approve(address(dep.marginEngine), type(uint256).max);
        dep.marginEngine.deposit(address(m), trader, 5_000e6);
        (int256 filled,) = m.trade(50_000e6, 1e18, block.timestamp);
        vm.stopPrank();
        assertEq(filled, 50_000e6);
        assertGt(m.currentRate(), 0.04e18);

        // run to maturity with real source accrual
        uint256 mat = m.maturity();
        RateOracle o = RateOracle(dep.oracles[0]);
        while (block.timestamp < mat + 1 hours) {
            vm.warp(block.timestamp + 1 days);
            o.snapshot();
        }
        int256 c1 = m.settle(trader);
        int256 c2 = m.settle(lp);
        assertLe(c1 + c2, 0);
        assertGe(c1 + c2, -2);
        uint256 bal = dep.marginEngine.marginOf(address(m), trader);
        vm.prank(trader);
        dep.marginEngine.withdraw(address(m), bal, trader);
    }

    function test_fork_fixedRateVault_spUSDG() public onlyFork {
        SwapMarket m = SwapMarket(dep.markets[4].market); // spUSDG 91D
        FixedRateVault v = FixedRateVault(dep.markets[4].vault);
        vm.startPrank(lp);
        IERC20(USDG).approve(address(dep.marginEngine), type(uint256).max);
        dep.marginEngine.deposit(address(m), lp, 300_000e6);
        m.mint(100, 700, 5e12);
        vm.stopPrank();

        vm.startPrank(saver);
        IERC20(USDG).approve(address(v), type(uint256).max);
        uint256 shares = v.deposit(10_000e6, saver);
        vm.stopPrank();
        assertGt(shares, 0);
        assertGt(IERC4626(SPARK).balanceOf(address(v)), 0); // really deposited into Spark on the fork
        (int256 vs,) = m.rawBalances(address(v));
        assertLt(vs, 0);

        uint256 mat = m.maturity();
        RateOracle o = RateOracle(dep.oracles[1]);
        while (block.timestamp < mat + 1 hours) {
            vm.warp(block.timestamp + 2 days);
            o.snapshot();
        }
        v.settleVault();
        uint256 out = v.maxWithdraw(saver);
        assertGt(out, 10_000e6); // locked a positive fixed rate
        vm.prank(saver);
        v.withdraw(out, saver, saver);
    }

    function test_fork_syrupFeedSource() public onlyFork {
        RateOracle o = RateOracle(dep.oracles[2]);
        assertTrue(o.isHealthy());
        // feed updates are pushed by Maple; a warp past maxAge makes the source stale -> oracle unhealthy later
        vm.warp(block.timestamp + 3 days);
        assertFalse(o.snapshot()); // stale feed: read fails, nothing written
        assertFalse(o.isHealthy());
    }
}

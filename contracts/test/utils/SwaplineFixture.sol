// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SwaplineDeployer} from "../../script/SwaplineDeployer.sol";
import {MockERC20, MockYieldVault, MockAggregator, MockSparkVault} from "./Mocks.sol";
import {SwapMarket} from "../../src/core/SwapMarket.sol";
import {RateVAMM} from "../../src/core/RateVAMM.sol";
import {RateOracle} from "../../src/oracle/RateOracle.sol";
import {FixedRateVault} from "../../src/vault/FixedRateVault.sol";
import {IMarginEngine} from "../../src/interfaces/IMarginEngine.sol";

/// @dev Full-system fixture built through the production deployer (SwaplineDeployer) with mock externals.
abstract contract SwaplineFixture is Test, SwaplineDeployer {
    MockERC20 internal usdg;
    MockAggregator internal usdgFeed;
    MockYieldVault internal yv; // ERC-4626 source (stands in for steakUSDG)
    MockSparkVault internal spark;
    MockAggregator internal syrupFeed;
    MockERC20 internal syrup;

    Deployment internal d;
    SwapMarket internal market; // yv source, 91-day maturity
    RateVAMM internal vamm;
    RateOracle internal oracle;
    FixedRateVault internal vault;

    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal lp1 = makeAddr("lp1");
    address internal lp2 = makeAddr("lp2");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant START = 1_790_000_000; // fixed, realistic timestamp

    function setUp() public virtual {
        vm.warp(START);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        usdgFeed = new MockAggregator(8, 1e8);
        yv = new MockYieldVault(usdg);
        usdg.mint(address(this), 10_000_000e6);
        usdg.approve(address(yv), type(uint256).max);
        yv.deposit(10_000_000e6, address(this)); // 10M TVL
        spark = new MockSparkVault(address(usdg));
        syrupFeed = new MockAggregator(18, 1e18);
        syrup = new MockERC20("syrupUSDG", "syrupUSDG", 6);
        syrup.mint(address(this), 5_000_000e6);

        _store(_deploySwapline(_config()));
        // markets[0..2] = yv source (30/91/182d), [3..5] spark, [6..8] chainlink
        market = SwapMarket(d.markets[1].market);
        vamm = RateVAMM(d.markets[1].vamm);
        oracle = RateOracle(d.oracles[0]);
        vault = FixedRateVault(d.markets[1].vault);

        address[8] memory users = [alice, bob, carol, lp1, lp2, keeper, guardian, treasury];
        for (uint256 i; i < users.length; ++i) {
            usdg.mint(users[i], 10_000_000e6);
            vm.prank(users[i]);
            usdg.approve(address(d.marginEngine), type(uint256).max);
        }
    }

    function _config() internal view virtual returns (Config memory c) {
        c.deployer = address(this);
        c.stablecoin = address(usdg);
        c.stablecoinUsdFeed = address(usdgFeed);
        c.stablecoinHeartbeat = 1 days + 2 hours;
        c.guardian = guardian;
        c.proposer = address(this);
        c.treasury = treasury;
        c.timelockDelay = 48 hours;
        c.maturityDays = new uint256[](3);
        c.maturityDays[0] = 30;
        c.maturityDays[1] = 91;
        c.maturityDays[2] = 182;
        c.sources = new SourceConfig[](3);
        c.sources[0] = SourceConfig({
            key: "mYLD",
            kind: SourceKind.ERC4626,
            target: address(yv),
            yieldToken: address(yv),
            maxAge: 0,
            maxRatePerYear: 0.3e18,
            initialRate: 0.05e18,
            fixedRateVault: true,
            description: "Mock ERC4626"
        });
        c.sources[1] = SourceConfig({
            key: "mSPK",
            kind: SourceKind.Spark,
            target: address(spark),
            yieldToken: address(spark),
            maxAge: 0,
            maxRatePerYear: 0.3e18,
            initialRate: 0.04e18,
            fixedRateVault: false,
            description: "Mock Spark"
        });
        c.sources[2] = SourceConfig({
            key: "mSYR",
            kind: SourceKind.Chainlink,
            target: address(syrupFeed),
            yieldToken: address(syrup),
            maxAge: 2 days,
            maxRatePerYear: 0.3e18,
            initialRate: 0.06e18,
            fixedRateVault: false,
            description: "Mock feed"
        });
    }

    // ------------------------------------------------------------------------------------------ helpers

    function _store(Deployment memory dm) internal {
        d.timelock = dm.timelock;
        d.compliance = dm.compliance;
        d.oracleAdapter = dm.oracleAdapter;
        d.marginEngine = dm.marginEngine;
        d.lpPositions = dm.lpPositions;
        d.factory = dm.factory;
        d.liquidator = dm.liquidator;
        d.feeCollector = dm.feeCollector;
        d.projectTokenHooks = dm.projectTokenHooks;
        d.rateSources = dm.rateSources;
        d.oracles = dm.oracles;
        delete d.markets;
        for (uint256 i; i < dm.markets.length; ++i) {
            d.markets.push(dm.markets[i]);
        }
    }

    /// @dev Grow the ERC-4626 mock's share price by `bps` (simulated yield via asset mint into the vault).
    function _accrue(uint256 bps) internal {
        uint256 ta = yv.totalAssets();
        usdg.mint(address(yv), (ta * bps) / 10_000);
    }

    /// @dev Advance time, accrue `apr` simple yield over it, and snapshot all oracles.
    function _pass(uint256 dt, uint256 apr) internal {
        uint256 ta = yv.totalAssets();
        vm.warp(block.timestamp + dt);
        usdg.mint(address(yv), (ta * apr * dt) / (365 days * 1e18));
        syrupFeed.set(syrupFeed.answer(), block.timestamp);
        usdgFeed.set(1e8, block.timestamp);
        for (uint256 i; i < d.oracles.length; ++i) {
            RateOracle(d.oracles[i]).snapshot();
        }
    }

    function _deposit(address who, SwapMarket m, uint256 amount) internal {
        vm.prank(who);
        d.marginEngine.deposit(address(m), who, amount);
    }

    function _mint(address who, SwapMarket m, int24 lower, int24 upper, uint128 liq) internal {
        vm.prank(who);
        m.mint(lower, upper, liq);
    }

    function _trade(address who, SwapMarket m, int256 notional) internal returns (int256 filled, uint256 fee) {
        uint256 limit = notional > 0 ? 1e18 : 0;
        vm.prank(who);
        return m.trade(notional, limit, block.timestamp);
    }

    /// @dev Standard book: lp1 provides L=1e12 (1M USDG per 100% rate) over [2%, 8%).
    function _seedLiquidity(SwapMarket m) internal {
        _deposit(lp1, m, 100_000e6);
        _mint(lp1, m, 200, 800, 1e12);
    }

    function _asTimelock() internal {
        vm.prank(address(d.timelock));
    }

    function _risk() internal pure returns (IMarginEngine.RiskParams memory) {
        return _riskParams();
    }
}

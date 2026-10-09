// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RateOracle} from "../../src/oracle/RateOracle.sol";
import {IRateOracle} from "../../src/interfaces/IRateOracle.sol";
import {IRateSource} from "../../src/interfaces/IRateSource.sol";
import {ERC4626RateSource} from "../../src/oracle/sources/ERC4626RateSource.sol";
import {SparkVaultRateSource, ISparkVault} from "../../src/oracle/sources/SparkVaultRateSource.sol";
import {ChainlinkRateSource} from "../../src/oracle/sources/ChainlinkRateSource.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {Roles} from "../../src/libraries/Roles.sol";
import {MockRateSource, MockERC20, MockYieldVault, MockSparkVault, MockAggregator} from "../utils/Mocks.sol";

contract RateOracleTest is Test {
    MockRateSource src;
    RateOracle oracle;
    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");

    function setUp() public {
        vm.warp(1_790_000_000);
        src = new MockRateSource(address(1));
        oracle = new RateOracle(IRateSource(address(src)), admin, 1 hours, 2 days, 0.3e18);
        vm.prank(admin);
        oracle.grantRole(Roles.GUARDIAN_ROLE, guardian);
    }

    function _grow(uint256 dt, uint256 apr) internal {
        vm.warp(block.timestamp + dt);
        src.setIndex(src.index() + (src.index() * apr * dt) / (365 days * 1e18));
    }

    function test_constructor_recordsFirstObservation() public view {
        IRateOracle.Observation memory o = oracle.latestObservation();
        assertEq(o.index, 1e18);
        assertEq(o.timestamp, block.timestamp);
        assertEq(oracle.observationCount(), 1);
        assertEq(oracle.lastRawIndex(), 1e18);
    }

    function test_constructor_revertsOnBadParams() public {
        vm.expectRevert(RateOracle.InvalidParams.selector);
        new RateOracle(IRateSource(address(0)), admin, 1 hours, 2 days, 0.3e18);
        vm.expectRevert(RateOracle.InvalidParams.selector);
        new RateOracle(IRateSource(address(src)), admin, 0, 2 days, 0.3e18);
        vm.expectRevert(RateOracle.InvalidParams.selector);
        new RateOracle(IRateSource(address(src)), admin, 3 days, 2 days, 0.3e18);
        vm.expectRevert(RateOracle.InvalidParams.selector);
        new RateOracle(IRateSource(address(src)), admin, 1 hours, 2 days, 11e18);
        src.setIndex(0);
        vm.expectRevert(RateOracle.InvalidIndex.selector);
        new RateOracle(IRateSource(address(src)), admin, 1 hours, 2 days, 0.3e18);
    }

    function test_snapshot_respectsMinInterval() public {
        assertFalse(oracle.snapshotDue());
        assertFalse(oracle.snapshot());
        vm.warp(block.timestamp + 1 hours);
        assertTrue(oracle.snapshotDue());
        assertTrue(oracle.snapshot());
        assertEq(oracle.observationCount(), 2);
    }

    function test_realizedRate_matchesGrowth() public {
        uint256 t0 = block.timestamp;
        for (uint256 i; i < 30; ++i) {
            _grow(1 days, 0.05e18);
            oracle.snapshot();
        }
        int256 r = oracle.realizedRate(t0, block.timestamp);
        // 30 days of daily-compounded 5% APR -> realised simple annualised ~5.01%
        assertApproxEqRel(uint256(r), 0.0501e18, 0.001e18);
    }

    function test_indexAt_interpolates() public {
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 10 hours);
        src.setIndex(1.0001e18); // 8.76% APR, below the 30% clamp
        oracle.snapshot();
        assertEq(oracle.indexAt(t0 + 5 hours), 1.00005e18);
        assertEq(oracle.indexAt(t0), 1e18);
        assertEq(oracle.indexAt(t0 + 10 hours), 1.0001e18);
    }

    function test_indexAt_revertsOutsideRange() public {
        uint256 t0 = block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(RateOracle.TimestampTooOld.selector, t0 - 1, t0));
        oracle.indexAt(t0 - 1);
        vm.warp(t0 + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(RateOracle.TimestampNotObserved.selector, t0 + 1 hours, t0));
        oracle.indexAt(t0 + 1 hours);
        // asking for "now" returns the live index
        src.setIndex(1.00001e18);
        assertEq(oracle.indexAt(block.timestamp), 1.00001e18);
    }

    function test_donationIsClampedAndDiscarded() public {
        // a 10% instantaneous jump (donation) after 1 day: cap = 30%/yr * 1d ~ 0.082%
        vm.warp(block.timestamp + 1 days);
        src.setIndex(1.1e18);
        oracle.snapshot();
        uint256 cap30 = 0.3e18;
        uint256 capped = 1e18 + (cap30 * 1 days) / 365 days;
        assertEq(oracle.latestObservation().index, capped);
        // the next period's normal growth is chained from the raw index, so the excess never comes back
        _grow(1 days, 0.05e18);
        oracle.snapshot();
        uint256 five = 0.05e18;
        uint256 expected = (capped * (1e18 + (five * 1 days) / 365 days)) / 1e18;
        assertApproxEqAbs(oracle.latestObservation().index, expected, 2);
        // live index also clamps
        vm.warp(block.timestamp + 1 hours);
        src.setIndex(src.index() * 2);
        assertLe(oracle.currentIndex(), (expected * (1e18 + (cap30 * 1 hours) / 365 days)) / 1e18 + 1);
    }

    function test_decreaseFlagsImpairment_andPassesLossThrough() public {
        vm.warp(block.timestamp + 1 days);
        src.setIndex(0.9e18);
        vm.expectEmit(false, false, false, true);
        emit IRateOracle.SourceImpaired(0.9e18, 1e18, block.timestamp);
        oracle.snapshot();
        assertTrue(oracle.impaired());
        assertFalse(oracle.isHealthy());
        assertEq(oracle.latestObservation().index, 0.9e18);
        assertLt(oracle.realizedRate(block.timestamp - 1 days, block.timestamp), 0);
        // governance clears
        vm.prank(admin);
        oracle.clearImpairment();
        assertTrue(oracle.isHealthy());
    }

    function test_tinyDecreaseIsNotImpairment() public {
        vm.warp(block.timestamp + 1 hours);
        src.setIndex(1e18 - 1e11); // 1e-7 relative
        oracle.snapshot();
        assertFalse(oracle.impaired());
    }

    function test_guardianCanFlag_onlyAdminClears() public {
        vm.expectRevert();
        oracle.flagImpaired();
        vm.prank(guardian);
        oracle.flagImpaired();
        assertTrue(oracle.impaired());
        vm.prank(guardian);
        vm.expectRevert();
        oracle.clearImpairment();
    }

    function test_staleness_makesUnhealthy() public {
        assertTrue(oracle.isHealthy());
        vm.warp(block.timestamp + 2 days + 1);
        assertFalse(oracle.isHealthy());
        oracle.snapshot();
        assertTrue(oracle.isHealthy());
    }

    function test_sourceRevert_isHandled() public {
        vm.warp(block.timestamp + 1 hours);
        src.setReverts(true);
        assertFalse(oracle.snapshot());
        assertFalse(oracle.isHealthy());
        assertEq(oracle.currentIndex(), 1e18); // falls back to last observation
        src.setReverts(false);
        src.setIndex(0);
        assertFalse(oracle.snapshot());
        assertEq(oracle.currentIndex(), 1e18);
    }

    function test_ringBufferWraps_andStaysBounded() public {
        uint256 cap = oracle.CAPACITY();
        for (uint256 i; i < cap + 10; ++i) {
            _grow(1 hours, 0.04e18);
            oracle.snapshot();
        }
        assertEq(oracle.observationCount(), cap);
        IRateOracle.Observation memory oldest = oracle.oldestObservation();
        IRateOracle.Observation memory latest = oracle.latestObservation();
        assertEq(latest.timestamp - oldest.timestamp, (cap - 1) * 1 hours);
        assertEq(oracle.observationAt(0).timestamp, oldest.timestamp);
        assertEq(oracle.observationAt(cap - 1).timestamp, latest.timestamp);
        // interpolation still works inside the buffer
        uint256 mid = oldest.timestamp + 500 hours + 30 minutes;
        uint256 a = oracle.indexAt(mid - 30 minutes);
        uint256 b = oracle.indexAt(mid + 30 minutes);
        assertEq(oracle.indexAt(mid), a + (b - a) / 2);
        vm.expectRevert();
        oracle.observationAt(cap);
        vm.expectRevert();
        oracle.indexAt(oldest.timestamp - 1);
    }

    function test_currentFloatingRate() public {
        for (uint256 i; i < 10; ++i) {
            _grow(1 days, 0.04e18);
            oracle.snapshot();
        }
        int256 r = oracle.currentFloatingRate(7 days);
        assertApproxEqRel(uint256(r), 0.04e18, 0.01e18);
        // lookback longer than the buffer is bounded by the oldest observation
        int256 rAll = oracle.currentFloatingRate(3650 days);
        assertApproxEqRel(uint256(rAll), 0.04e18, 0.01e18);
        assertEq(oracle.currentFloatingRate(0), 0);
    }

    function test_realizedRate_invalidRange() public {
        vm.expectRevert(RateOracle.InvalidRange.selector);
        oracle.realizedRate(block.timestamp, block.timestamp);
    }

    function test_setParams() public {
        vm.expectRevert();
        oracle.setParams(2 hours, 3 days, 0.2e18);
        vm.prank(admin);
        oracle.setParams(2 hours, 3 days, 0.2e18);
        assertEq(oracle.minInterval(), 2 hours);
        assertEq(oracle.maxStaleness(), 3 days);
        assertEq(oracle.maxRatePerYear(), 0.2e18);
    }
}

contract RateSourcesTest is Test {
    MockERC20 usdg;

    function setUp() public {
        vm.warp(1_790_000_000);
        usdg = new MockERC20("USDG", "USDG", 6);
    }

    function test_erc4626Source() public {
        MockYieldVault v = new MockYieldVault(usdg);
        usdg.mint(address(this), 1_000_000e6);
        usdg.approve(address(v), type(uint256).max);
        v.deposit(1_000_000e6, address(this));
        ERC4626RateSource s = new ERC4626RateSource(v, "mock");
        assertApproxEqRel(s.currentIndex(), 1e18, 1e12);
        usdg.mint(address(v), 10_000e6); // +1%
        assertApproxEqRel(s.currentIndex(), 1.01e18, 1e12);
        assertEq(s.totalValue(), 1_010_000e6);
        assertEq(s.underlying(), address(usdg));
        assertEq(s.description(), "mock");
        vm.expectRevert(ERC4626RateSource.ZeroAddress.selector);
        new ERC4626RateSource(MockYieldVault(address(0)), "x");
    }

    function test_sparkSource() public {
        MockSparkVault v = new MockSparkVault(address(usdg));
        SparkVaultRateSource s = new SparkVaultRateSource(ISparkVault(address(v)), "spark");
        assertEq(s.currentIndex(), 1e18);
        v.setChi(1.0103e27);
        assertEq(s.currentIndex(), 1.0103e18);
        assertEq(s.totalValue(), 1e12);
        assertEq(s.underlying(), address(usdg));
        assertEq(s.description(), "spark");
        vm.expectRevert(SparkVaultRateSource.ZeroAddress.selector);
        new SparkVaultRateSource(ISparkVault(address(0)), "x");
    }

    function test_chainlinkSource() public {
        MockAggregator f = new MockAggregator(18, 1.014e18);
        MockERC20 y = new MockERC20("syrup", "syrup", 6);
        y.mint(address(this), 1_000e6);
        ChainlinkRateSource s = new ChainlinkRateSource(IAggregatorV3(address(f)), y, address(usdg), 2 days, "syrup");
        assertEq(s.currentIndex(), 1.014e18);
        assertEq(s.totalValue(), 1_014e6);
        assertEq(s.description(), "syrup");
        vm.warp(block.timestamp + 2 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkRateSource.StaleFeed.selector, block.timestamp - 2 days - 1));
        s.currentIndex();
        f.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkRateSource.InvalidAnswer.selector, int256(0)));
        s.currentIndex();
        f.set(1e18, block.timestamp + 10);
        vm.expectRevert();
        s.currentIndex();
        vm.expectRevert(ChainlinkRateSource.ZeroAddress.selector);
        new ChainlinkRateSource(IAggregatorV3(address(0)), y, address(usdg), 1, "x");
    }

    function test_chainlinkSource_8decimals() public {
        MockAggregator f = new MockAggregator(8, 1.05e8);
        MockERC20 y = new MockERC20("y", "y", 6);
        ChainlinkRateSource s = new ChainlinkRateSource(IAggregatorV3(address(f)), y, address(usdg), 1 days, "y");
        assertEq(s.currentIndex(), 1.05e18);
    }
}

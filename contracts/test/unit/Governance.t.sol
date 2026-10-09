// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SwaplineFixture} from "../utils/SwaplineFixture.sol";
import {MockAggregator} from "../utils/Mocks.sol";
import {SwaplineTimelock} from "../../src/governance/SwaplineTimelock.sol";
import {OracleAdapter} from "../../src/periphery/OracleAdapter.sol";
import {ComplianceRegistry} from "../../src/compliance/ComplianceRegistry.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {MarketFactory} from "../../src/core/MarketFactory.sol";
import {SwapMarket} from "../../src/core/SwapMarket.sol";
import {RateVAMM} from "../../src/core/RateVAMM.sol";
import {RateOracle} from "../../src/oracle/RateOracle.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {Roles} from "../../src/libraries/Roles.sol";

contract GovernanceTest is SwaplineFixture {
    // ------------------------------------------------------------------ hand-off

    function test_deployerHoldsNoRoles_timelockIsAdmin() public view {
        address tl = address(d.timelock);
        assertTrue(d.marginEngine.hasRole(0x00, tl));
        assertFalse(d.marginEngine.hasRole(0x00, address(this)));
        assertFalse(d.factory.hasRole(0x00, address(this)));
        assertFalse(d.lpPositions.hasRole(0x00, address(this)));
        assertFalse(d.compliance.hasRole(0x00, address(this)));
        assertFalse(d.oracleAdapter.hasRole(0x00, address(this)));
        assertFalse(d.liquidator.hasRole(0x00, address(this)));
        assertFalse(d.feeCollector.hasRole(0x00, address(this)));
        assertFalse(d.projectTokenHooks.hasRole(0x00, address(this)));
        for (uint256 i; i < d.oracles.length; ++i) {
            assertFalse(RateOracle(d.oracles[i]).hasRole(0x00, address(this)));
            assertTrue(RateOracle(d.oracles[i]).hasRole(0x00, tl));
            assertTrue(RateOracle(d.oracles[i]).hasRole(Roles.GUARDIAN_ROLE, guardian));
        }
        assertTrue(d.marginEngine.hasRole(Roles.GUARDIAN_ROLE, guardian));
        assertTrue(d.marginEngine.hasRole(Roles.LIQUIDATOR_ROLE, address(d.liquidator)));
        assertEq(d.timelock.getMinDelay(), 48 hours);
        assertEq(d.factory.marketCount(), 9);
        assertEq(d.factory.markets().length, 9);
        assertEq(address(d.projectTokenHooks.projectToken()), address(0));
    }

    function test_timelock_enforces48h_endToEnd() public {
        // schedule an unpause through the timelock (proposer = this test, executor = anyone)
        vm.prank(guardian);
        d.marginEngine.pause();
        bytes memory call = abi.encodeWithSignature("unpause()");
        d.timelock.schedule(address(d.marginEngine), 0, call, bytes32(0), bytes32(0), 48 hours);
        vm.expectRevert();
        d.timelock.execute(address(d.marginEngine), 0, call, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(carol); // anyone executes
        d.timelock.execute(address(d.marginEngine), 0, call, bytes32(0), bytes32(0));
        assertFalse(d.marginEngine.paused());
        // shorter delays are rejected at schedule time
        vm.expectRevert();
        d.timelock.schedule(address(d.marginEngine), 0, call, bytes32(0), bytes32(uint256(1)), 1 hours);
    }

    function test_timelock_delayFloor() public {
        address[] memory a = new address[](1);
        a[0] = address(this);
        vm.expectRevert(SwaplineTimelock.DelayTooShort.selector);
        new SwaplineTimelock(1 days, a, a);
        vm.expectRevert();
        d.timelock.updateDelay(72 hours); // only via itself
        vm.prank(address(d.timelock));
        vm.expectRevert(SwaplineTimelock.DelayTooShort.selector);
        d.timelock.updateDelay(1 hours);
        vm.prank(address(d.timelock));
        d.timelock.updateDelay(72 hours);
        assertEq(d.timelock.getMinDelay(), 72 hours);
    }

    // ------------------------------------------------------------------ factory

    function test_factory_createMarket_onlyAdmin_noDuplicates() public {
        MarketFactory.CreateParams memory p = MarketFactory.CreateParams({
            oracle: RateOracle(d.oracles[0]),
            maturity: block.timestamp + 365 days,
            tickSpacing: 10,
            initialRate: 0.05e18,
            marketParams: _marketParams(),
            riskParams: _riskParams()
        });
        vm.expectRevert();
        d.factory.createMarket(p);
        _asTimelock();
        address m = d.factory.createMarket(p);
        assertEq(d.factory.marketFor(d.oracles[0], p.maturity), m);
        assertTrue(d.lpPositions.isMarket(m));
        assertEq(SwapMarket(m).maturity(), p.maturity);
        _asTimelock();
        vm.expectRevert(MarketFactory.MarketExists.selector);
        d.factory.createMarket(p);
        // implementation cannot be initialised directly
        SwapMarket impl = SwapMarket(d.factory.marketImplementation());
        RateVAMM mv = SwapMarket(m).vammContract();
        RateOracle o = RateOracle(d.oracles[0]);
        SwapMarket.MarketParams memory mp = _marketParams();
        vm.expectRevert();
        impl.initialize(d.marginEngine, mv, d.lpPositions, o, block.timestamp + 1 days, mp);
    }

    function test_factory_rejectsPastMaturity() public {
        MarketFactory.CreateParams memory p = MarketFactory.CreateParams({
            oracle: RateOracle(d.oracles[0]),
            maturity: block.timestamp,
            tickSpacing: 10,
            initialRate: 0.05e18,
            marketParams: _marketParams(),
            riskParams: _riskParams()
        });
        _asTimelock();
        vm.expectRevert(SwapMarket.InvalidParams.selector);
        d.factory.createMarket(p);
    }

    // ------------------------------------------------------------------ oracle adapter

    function test_oracleAdapter_stalenessDeviationSequencer() public {
        OracleAdapter a = d.oracleAdapter;
        assertEq(a.getPrice(address(usdg)), 1e18);
        assertTrue(a.isCollateralHealthy(address(usdg)));
        usdgFeed.set(0.985e8, block.timestamp);
        assertTrue(a.isCollateralHealthy(address(usdg))); // within 2%
        usdgFeed.set(0.97e8, block.timestamp);
        assertFalse(a.isCollateralHealthy(address(usdg)));
        usdgFeed.set(1e8, block.timestamp - 27 hours);
        assertFalse(a.isCollateralHealthy(address(usdg)));
        vm.expectRevert();
        a.getPrice(address(usdg));
        usdgFeed.set(-1, block.timestamp);
        vm.expectRevert();
        a.getPrice(address(usdg));
        usdgFeed.set(1e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnsupportedToken.selector, address(syrup)));
        a.getPrice(address(syrup));
        assertFalse(a.isCollateralHealthy(address(syrup)));

        // sequencer feed: down, then up but within grace
        MockAggregator seq = new MockAggregator(0, 1);
        _asTimelock();
        a.setSequencerFeed(IAggregatorV3(address(seq)), 1 hours);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        a.getPrice(address(usdg));
        seq.set(0, block.timestamp);
        seq.setStartedAt(block.timestamp);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        a.getPrice(address(usdg));
        vm.warp(block.timestamp + 2 hours);
        usdgFeed.set(1e8, block.timestamp);
        assertEq(a.getPrice(address(usdg)), 1e18);

        // no peg configured => healthy whenever fresh
        _asTimelock();
        a.setFeed(
            address(syrup),
            OracleAdapter.FeedConfig({feed: IAggregatorV3(address(syrupFeed)), heartbeat: 3 days, peg: 0, maxDeviation: 0})
        );
        assertTrue(a.isCollateralHealthy(address(syrup)));
        _asTimelock();
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        a.setFeed(address(0), OracleAdapter.FeedConfig({feed: IAggregatorV3(address(0)), heartbeat: 0, peg: 0, maxDeviation: 0}));
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        new OracleAdapter(address(0));
    }

    // ------------------------------------------------------------------ compliance

    function test_compliance_defaultsOff_batchLimit() public {
        ComplianceRegistry c = d.compliance;
        assertFalse(c.enabled());
        assertTrue(c.isAllowed(alice, IComplianceRegistry.Action.Trade));
        address[] memory big = new address[](201);
        _asTimelock();
        vm.expectRevert(ComplianceRegistry.BatchTooLarge.selector);
        c.setAllowlisted(big, true);
        address[] memory one = new address[](1);
        one[0] = alice;
        vm.expectRevert();
        c.setAllowlisted(one, true); // not compliance role
        vm.expectRevert();
        c.setEnabled(true);
    }

    function test_standaloneTimelock_updateDelay() public {
        address[] memory a = new address[](1);
        a[0] = address(this);
        SwaplineTimelock t = new SwaplineTimelock(48 hours, a, a);
        assertEq(t.getMinDelay(), 48 hours);
        vm.expectRevert();
        t.updateDelay(96 hours);
        bytes memory call = abi.encodeCall(SwaplineTimelock.updateDelay, (96 hours));
        t.schedule(address(t), 0, call, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        t.execute(address(t), 0, call, bytes32(0), bytes32(0));
        assertEq(t.getMinDelay(), 96 hours);
        bytes memory bad = abi.encodeCall(SwaplineTimelock.updateDelay, (1 hours));
        t.schedule(address(t), 0, bad, bytes32(0), bytes32(uint256(1)), 96 hours);
        vm.warp(block.timestamp + 96 hours);
        vm.expectRevert(SwaplineTimelock.DelayTooShort.selector);
        t.execute(address(t), 0, bad, bytes32(0), bytes32(uint256(1)));
    }
}

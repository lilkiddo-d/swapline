// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SwaplineFixture} from "../utils/SwaplineFixture.sol";
import {MockERC20} from "../utils/Mocks.sol";
import {ProjectTokenHooks} from "../../src/token/ProjectTokenHooks.sol";
import {FeeCollector, IInsuranceSink, IStakingRewards} from "../../src/fees/FeeCollector.sol";

/// @dev $SWPL is represented by a MOCK ERC-20 that exists only in tests. Swapline deploys no token.
contract TokenAndFeesTest is SwaplineFixture {
    MockERC20 swpl;
    ProjectTokenHooks hooks;

    function setUp() public override {
        super.setUp();
        hooks = d.projectTokenHooks;
        swpl = new MockERC20("Mock SWPL", "mSWPL", 18);
        swpl.mint(alice, 1_000e18);
        swpl.mint(bob, 3_000e18);
        vm.prank(alice);
        swpl.approve(address(hooks), type(uint256).max);
        vm.prank(bob);
        swpl.approve(address(hooks), type(uint256).max);
    }

    function _setToken() internal {
        _asTimelock();
        hooks.setProjectToken(address(swpl));
    }

    function _generateFees() internal {
        _seedLiquidity(market);
        _deposit(carol, market, 5_000e6);
        _trade(carol, market, 20_000e6);
    }

    // ------------------------------------------------------------------ token unset: protocol works, features off

    function test_tokenUnset_featuresDisabled_protocolWorks() public {
        assertFalse(hooks.tokenSet());
        assertFalse(hooks.rewardsActive());
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.stake(1e18);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.propose(ProjectTokenHooks.ProposalKind.NewMaturity, bytes32(0), "x");
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.vote(0, true);
        vm.expectRevert(ProjectTokenHooks.TokenNotSet.selector);
        hooks.notifyRewardAmount(1);
        // fees flow entirely to insurance + treasury
        _generateFees();
        uint256 bal = usdg.balanceOf(address(d.feeCollector));
        assertGt(bal, 0);
        uint256 insBefore = d.marginEngine.insuranceFund();
        (uint256 ins, uint256 stk, uint256 tre) = d.feeCollector.distribute();
        assertEq(stk, 0);
        assertEq(ins, bal * 2_000 / 10_000);
        assertEq(tre, bal - ins);
        assertEq(d.marginEngine.insuranceFund() - insBefore, ins);
        assertEq(usdg.balanceOf(treasury), 10_000_000e6 + tre);
        // empty distribute is a no-op
        (ins, stk, tre) = d.feeCollector.distribute();
        assertEq(ins + stk + tre, 0);
    }

    // ------------------------------------------------------------------ setProjectToken: once, timelock only

    function test_setProjectToken_onlyTimelock_once() public {
        vm.expectRevert();
        hooks.setProjectToken(address(swpl));
        vm.prank(guardian);
        vm.expectRevert();
        hooks.setProjectToken(address(swpl));
        _asTimelock();
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        hooks.setProjectToken(address(0));
        _asTimelock();
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        hooks.setProjectToken(alice); // EOA
        _asTimelock();
        vm.expectRevert(ProjectTokenHooks.InvalidToken.selector);
        hooks.setProjectToken(address(usdg)); // reward token
        _setToken();
        assertTrue(hooks.tokenSet());
        _asTimelock();
        vm.expectRevert(ProjectTokenHooks.TokenAlreadySet.selector);
        hooks.setProjectToken(address(swpl));
    }

    // ------------------------------------------------------------------ staking + fee sharing

    function test_stakersShareFees() public {
        _setToken();
        vm.prank(alice);
        hooks.stake(1_000e18);
        vm.prank(bob);
        hooks.stake(3_000e18);
        assertTrue(hooks.rewardsActive());
        _generateFees();
        uint256 bal = usdg.balanceOf(address(d.feeCollector));
        (, uint256 stk,) = d.feeCollector.distribute();
        assertEq(stk, bal * 5_000 / 10_000);
        assertApproxEqAbs(hooks.earned(alice), stk / 4, 1);
        assertApproxEqAbs(hooks.earned(bob), (stk * 3) / 4, 1);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        uint256 got = hooks.claim();
        assertEq(usdg.balanceOf(alice) - before, got);
        assertEq(hooks.earned(alice), 0);
        vm.prank(alice);
        assertEq(hooks.claim(), 0);
    }

    function test_unstakeCooldown() public {
        _setToken();
        vm.prank(alice);
        hooks.stake(1_000e18);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.InsufficientStake.selector);
        hooks.requestUnstake(2_000e18);
        vm.prank(alice);
        hooks.requestUnstake(400e18);
        assertEq(hooks.stakeOf(alice), 600e18);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.CooldownActive.selector);
        hooks.withdraw();
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        hooks.withdraw();
        assertEq(swpl.balanceOf(alice), 400e18);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.withdraw();
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.stake(0);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.requestUnstake(0);
    }

    function test_notify_requiresStakers() public {
        _setToken();
        vm.prank(carol);
        vm.expectRevert(ProjectTokenHooks.NoStakers.selector);
        hooks.notifyRewardAmount(1e6);
        vm.prank(alice);
        hooks.stake(1e18);
        vm.prank(carol);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        hooks.notifyRewardAmount(0);
    }

    // ------------------------------------------------------------------ advisory votes

    function test_advisoryVote_flow_andNoDoubleVoting() public {
        _setToken();
        vm.prank(alice);
        hooks.stake(1_000e18);
        vm.prank(bob);
        hooks.stake(3_000e18);
        vm.prank(carol);
        vm.expectRevert(ProjectTokenHooks.InsufficientStake.selector);
        hooks.propose(ProjectTokenHooks.ProposalKind.NewRateSource, bytes32(0), "no stake");
        vm.prank(alice);
        uint256 id = hooks.propose(
            ProjectTokenHooks.ProposalKind.NewRateSource, keccak256("createMarket(...)"), "Add a 12-month market"
        );
        assertEq(hooks.proposalCount(), 1);
        vm.prank(alice);
        hooks.vote(id, true);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.AlreadyVoted.selector);
        hooks.vote(id, true);
        // alice cannot move her voted tokens to a fresh address before the vote ends (cooldown > voting period)
        vm.prank(alice);
        hooks.requestUnstake(1_000e18);
        vm.warp(block.timestamp + 5 days - 1);
        vm.prank(alice);
        vm.expectRevert(ProjectTokenHooks.CooldownActive.selector);
        hooks.withdraw();
        vm.prank(carol);
        vm.expectRevert(ProjectTokenHooks.NoVotingPower.selector);
        hooks.vote(id, false);
        vm.prank(bob);
        hooks.vote(id, false);
        assertFalse(hooks.passed(id)); // still open
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        vm.expectRevert(ProjectTokenHooks.VotingClosed.selector);
        hooks.vote(id, true);
        assertFalse(hooks.passed(id)); // 1000 for vs 3000 against
        ProjectTokenHooks.Proposal memory p = hooks.proposal(id);
        assertEq(p.forVotes, 1_000e18);
        assertEq(p.againstVotes, 3_000e18);
        vm.expectRevert(ProjectTokenHooks.UnknownProposal.selector);
        hooks.proposal(9);
        vm.expectRevert(ProjectTokenHooks.UnknownProposal.selector);
        hooks.vote(9, true);
        vm.expectRevert(ProjectTokenHooks.UnknownProposal.selector);
        hooks.passed(9);
    }

    function test_proposalPasses_withQuorum() public {
        _setToken();
        vm.prank(bob);
        hooks.stake(3_000e18);
        vm.prank(bob);
        uint256 id = hooks.propose(ProjectTokenHooks.ProposalKind.NewMaturity, bytes32(0), "add 12M");
        vm.prank(bob);
        hooks.vote(id, true);
        vm.warp(block.timestamp + 5 days);
        assertTrue(hooks.passed(id));
    }

    function test_governanceParams() public {
        vm.expectRevert();
        hooks.setGovernanceParams(7 days, 5 days, 0, 1_000);
        _asTimelock();
        vm.expectRevert(ProjectTokenHooks.InvalidParams.selector);
        hooks.setGovernanceParams(5 days, 5 days, 0, 1_000); // cooldown must exceed voting period
        _asTimelock();
        hooks.setGovernanceParams(10 days, 3 days, 100e18, 2_000);
        assertEq(hooks.cooldown(), 10 days);
        assertEq(hooks.proposalThreshold(), 100e18);
        string memory big = string(new bytes(2_001));
        _setToken();
        vm.prank(bob);
        hooks.stake(200e18);
        vm.prank(bob);
        vm.expectRevert(ProjectTokenHooks.InvalidParams.selector);
        hooks.propose(ProjectTokenHooks.ProposalKind.Other, bytes32(0), big);
    }

    function test_hooksConstructorGuards() public {
        vm.expectRevert(ProjectTokenHooks.InvalidParams.selector);
        new ProjectTokenHooks(usdg, address(0));
    }

    // ------------------------------------------------------------------ fee collector config

    function test_feeCollector_config() public {
        vm.expectRevert();
        d.feeCollector.setConfig(treasury, IInsuranceSink(address(0)), IStakingRewards(address(0)), 0, 0);
        _asTimelock();
        vm.expectRevert(FeeCollector.InvalidConfig.selector);
        d.feeCollector.setConfig(address(0), IInsuranceSink(address(0)), IStakingRewards(address(0)), 0, 0);
        _asTimelock();
        vm.expectRevert(FeeCollector.InvalidConfig.selector);
        d.feeCollector.setConfig(treasury, IInsuranceSink(address(0)), IStakingRewards(address(0)), 6_000, 5_000);
        _asTimelock();
        d.feeCollector.setConfig(treasury, IInsuranceSink(address(0)), IStakingRewards(address(0)), 0, 0);
        _generateFees();
        (uint256 ins, uint256 stk, uint256 tre) = d.feeCollector.distribute();
        assertEq(ins + stk, 0);
        assertGt(tre, 0);
        vm.expectRevert(FeeCollector.InvalidConfig.selector);
        new FeeCollector(usdg, address(0), treasury, IInsuranceSink(address(0)), 0, 0);
    }
}

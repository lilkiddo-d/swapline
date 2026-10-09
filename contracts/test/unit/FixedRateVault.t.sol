// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SwaplineFixture} from "../utils/SwaplineFixture.sol";
import {FixedRateVault} from "../../src/vault/FixedRateVault.sol";
import {SwapMarket} from "../../src/core/SwapMarket.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IComplianceRegistry} from "../../src/interfaces/IComplianceRegistry.sol";
import {MockYieldVault} from "../utils/Mocks.sol";

contract FixedRateVaultTest is SwaplineFixture {
    function setUp() public override {
        super.setUp();
        // deep book around 5% so the vault's receive-fixed hedge fills
        _deposit(lp1, market, 200_000e6);
        _mint(lp1, market, 200, 800, 5e12);
        vm.prank(alice);
        usdg.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdg.approve(address(vault), type(uint256).max);
    }

    function _runToMaturity(uint256 apr) internal {
        uint256 steps = (market.maturity() - block.timestamp) / 1 days + 1;
        for (uint256 i; i < steps; ++i) {
            _pass(1 days, apr);
        }
    }

    function test_deposit_hedges() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(10_000e6, alice);
        assertGt(shares, 0);
        (int256 vs,) = market.rawBalances(address(vault));
        assertLt(vs, 0); // pay floating / receive fixed
        assertApproxEqAbs(uint256(-vs) / 1e18, 9_500e6, 1); // notional = 95% of deposit
        assertEq(d.marginEngine.marginOf(address(market), address(vault)) + 0, 500e6 - _feeOf(9_500e6));
        assertApproxEqRel(vault.totalAssets(), 10_000e6, 0.002e18);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
    }

    function _feeOf(uint256 notional) internal view returns (uint256) {
        uint256 t = market.tau();
        uint256 feeX18 = notional * 1e18 * ((0.003e18 * t) / 1e18) / 1e18;
        return (feeX18 - 1) / 1e18 + 1;
    }

    /// @dev Core product property: the outcome is (almost) independent of the floating path.
    function test_fixedOutcome_independentOfFloating() public {
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        _runToMaturity(0.01e18); // floating 1%
        vault.settleVault();
        uint256 lowOut = vault.maxWithdraw(alice);

        vm.revertToState(snap);
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        _runToMaturity(0.12e18); // floating 12%
        vault.settleVault();
        uint256 highOut = vault.maxWithdraw(alice);

        // locked ~4.9% on 95% of principal for ~91 days -> ~ +116; outcomes within 0.05% of each other
        assertGt(lowOut, 10_100e6);
        assertApproxEqRel(lowOut, highOut, 0.0005e18);
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        uint256 got = vault.redeem(sh, alice, alice);
        assertEq(got, highOut);
    }

    function test_depositWithMinRate_enforced() public {
        vm.prank(alice);
        vm.expectRevert(); // rate would need to fall below 5.5%... limit 5.5% > spot 5% => invalid limit
        vault.depositWithMinRate(10_000e6, alice, 0.055e18);
        // 5e12 liquidity gives 5k of depth per 10bp: a 950 notional fills well above 4.9%
        vm.prank(alice);
        vault.depositWithMinRate(1_000e6, alice, 0.049e18);
        assertGe(market.currentRate(), 0.049e18);
        // too tight a floor for the size: reverts (all-or-nothing)
        vm.prank(alice);
        vm.expectRevert();
        vault.depositWithMinRate(100_000e6, alice, 0.0495e18);
    }

    function test_depositsClose_beforeMaturity_andWhenPaused() public {
        assertEq(vault.maxDeposit(alice), type(uint256).max);
        vm.prank(guardian);
        d.marginEngine.pause();
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        _asTimelock();
        d.marginEngine.unpause();
        vm.warp(market.maturity() - 1 days);
        assertEq(vault.maxDeposit(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1_000e6, alice);
    }

    function test_compliance_gatesVault() public {
        _asTimelock();
        d.compliance.setEnabled(true);
        assertEq(vault.maxDeposit(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1_000e6, alice);
        _asTimelock();
        d.compliance.setGated(IComplianceRegistry.Action.VaultDeposit, false);
        _asTimelock();
        d.compliance.setGated(IComplianceRegistry.Action.DepositMargin, false);
        _asTimelock();
        d.compliance.setGated(IComplianceRegistry.Action.Trade, false);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
    }

    function test_settleVault_guards_andRedeemSource() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.expectRevert(FixedRateVault.NotMatured.selector);
        vault.settleVault();
        vm.expectRevert(FixedRateVault.NotMatured.selector);
        vault.redeemSource();
        _runToMaturity(0.05e18);
        vault.settleVault();
        vm.expectRevert(FixedRateVault.AlreadySettled.selector);
        vault.settleVault();
        vault.redeemSource(); // no-op
        assertEq(vault.maxDeposit(alice), 0);
        assertGt(vault.maxRedeem(alice), 0);
    }

    function test_twoDepositors_shareFairly() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        _pass(10 days, 0.05e18);
        vm.prank(bob);
        vault.deposit(10_000e6, bob);
        _runToMaturity(0.05e18);
        vault.settleVault();
        uint256 a = vault.maxWithdraw(alice);
        uint256 b = vault.maxWithdraw(bob);
        assertGt(a, b); // alice was in longer
        assertGt(b, 10_000e6);
        vm.prank(alice);
        vault.withdraw(a, alice, alice);
        uint256 bobShares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);
    }

    function test_constructor_validation() public {
        MockYieldVault other = new MockYieldVault(syrup); // wrong asset
        vm.expectRevert(FixedRateVault.InvalidConfig.selector);
        new FixedRateVault(usdg, "x", "x", market, IERC4626(address(other)), 500, 0.005e18, 1 days);
        vm.expectRevert(FixedRateVault.InvalidConfig.selector);
        new FixedRateVault(usdg, "x", "x", market, IERC4626(address(yv)), 0, 0.005e18, 1 days);
        vm.expectRevert(FixedRateVault.InvalidConfig.selector);
        new FixedRateVault(usdg, "x", "x", market, IERC4626(address(yv)), 500, 0.5e18, 1 days);
    }

    function test_withdraw_pullsFromSourceWhenIdleShort() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        _runToMaturity(0.05e18);
        // settle the swap but leave source shares in place by settling via market directly first
        market.settle(address(vault));
        vault.settleVault(); // swap already settled -> skips settle, withdraws margin, redeems source
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(sh, alice, alice);
        assertEq(vault.totalSupply(), 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SwapMarket} from "../core/SwapMarket.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";
import {Constants} from "../libraries/Constants.sol";

/// @title FixedRateVault
/// @notice "Lock a fixed rate" for ordinary users. Each deposit of A stablecoin:
///           - posts m = A * marginBps as swap margin,
///           - deposits n = A - m into the floating source (e.g. Steakhouse USDG),
///           - enters a receive-fixed / pay-floating swap with notional n in the matching market.
///         The floating income on n is exactly offset by the floating leg paid, so at maturity the vault holds
///         n * (1 + r_fixed * tau) + m - fees, independent of where floating rates went.
/// @dev Term product: shares are freely transferable ERC-20s, but assets can only be withdrawn after maturity and
///      `settleVault()` (permissionless). The market's oracle MUST track `source` for the hedge to be exact; this is
///      checked at construction via the oracle source's underlying and verified in deployment tests.
contract FixedRateVault is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    SwapMarket public immutable market;
    IMarginEngine public immutable marginEngine;
    IERC4626 public immutable source;
    uint256 public immutable marginBps;
    uint256 public immutable maxSlippage; // max distance below spot fixed rate accepted on deposit (18 decimals)
    uint256 public immutable depositCutoff; // deposits close this long before maturity

    bool public swapSettled;
    uint256 private _minRate; // per-call override set by depositWithMinRate

    event Hedged(address indexed depositor, uint256 assets, uint256 margin, int256 notional, uint256 fixedRate);
    event VaultSettled(int256 swapCashflow, uint256 marginWithdrawn);

    error InvalidConfig();
    error SourceCallFailed();
    error DepositsClosed();
    error NotMatured();
    error NotAllowed();
    error AlreadySettled();

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        SwapMarket market_,
        IERC4626 source_,
        uint256 marginBps_,
        uint256 maxSlippage_,
        uint256 depositCutoff_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        if (source_.asset() != address(asset_) || market_.oracle().source().underlying() != address(asset_)) {
            revert InvalidConfig();
        }
        if (address(market_.marginEngine().token()) != address(asset_)) revert InvalidConfig();
        if (marginBps_ == 0 || marginBps_ >= Constants.BPS || maxSlippage_ > 0.05e18) revert InvalidConfig();
        market = market_;
        marginEngine = market_.marginEngine();
        source = source_;
        marginBps = marginBps_;
        maxSlippage = maxSlippage_;
        depositCutoff = depositCutoff_;
    }

    // ------------------------------------------------------------------------------------------ user entry

    // slither-disable-start reentrancy-no-eth
    // deposit() -> _deposit() is nonReentrant, so a callback from the source/market cannot re-enter and observe
    // or change _minRate; it is reset in the same call.
    /// @notice Deposit and require the locked fixed rate (average execution) to be at least `minRate`.
    function depositWithMinRate(uint256 assets, address receiver, uint256 minRate)
        external
        returns (uint256 shares)
    {
        _minRate = minRate;
        shares = deposit(assets, receiver);
        _minRate = 0;
    }
    // slither-disable-end reentrancy-no-eth

    /// @notice After maturity: settle the swap, pull margin back, and redeem the floating source. Permissionless.
    function settleVault() external nonReentrant {
        if (block.timestamp < market.maturity()) revert NotMatured();
        if (swapSettled) revert AlreadySettled();
        swapSettled = true;
        int256 cash = 0;
        if (!market.settled(address(this))) cash = market.settle(address(this));
        uint256 m = marginEngine.marginOf(address(market), address(this));
        if (m > 0) marginEngine.withdraw(address(market), m, address(this));
        _redeemSource(type(uint256).max);
        emit VaultSettled(cash, m);
    }

    /// @notice Pull any remaining source liquidity after settlement (if the source was liquidity-constrained).
    function redeemSource() external nonReentrant {
        if (!swapSettled) revert NotMatured();
        _redeemSource(type(uint256).max);
    }

    // ------------------------------------------------------------------------------------------ ERC-4626

    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 inSource = source.convertToAssets(source.balanceOf(address(this)));
        if (swapSettled) return idle + inSource;
        int256 equity = marginEngine.health(address(market), address(this)).equity;
        return idle + inSource + (equity > 0 ? uint256(equity) : 0);
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (!_depositsOpen(receiver)) return 0;
        return type(uint256).max;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        if (!_depositsOpen(receiver)) return 0;
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (!swapSettled) return 0;
        uint256 own = _convertToAssets(balanceOf(owner), _roundDown());
        uint256 avail = IERC20(asset()).balanceOf(address(this)) + source.maxWithdraw(address(this));
        return own < avail ? own : avail;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (!swapSettled) return 0;
        uint256 own = balanceOf(owner);
        uint256 availShares = _convertToShares(
            IERC20(asset()).balanceOf(address(this)) + source.maxWithdraw(address(this)), _roundDown()
        );
        return own < availShares ? own : availShares;
    }

    // ------------------------------------------------------------------------------------------ internal

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        if (!marginEngine.isAllowed(caller, IComplianceRegistry.Action.VaultDeposit)) revert NotAllowed();
        super._deposit(caller, receiver, assets, shares);
        _hedge(caller, assets);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        IERC20 a = IERC20(asset());
        uint256 idle = a.balanceOf(address(this));
        if (idle < assets) {
            // postcondition on our own balance rather than trusting the source's return value
            // slither-disable-start unused-return,reentrancy-balance
            source.withdraw(assets - idle, address(this), address(this));
            // slither-disable-end unused-return,reentrancy-balance
            if (a.balanceOf(address(this)) < assets) revert SourceCallFailed();
        }
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _hedge(address depositor, uint256 assets) internal {
        IERC20 a = IERC20(asset());
        uint256 m = (assets * marginBps) / Constants.BPS;
        uint256 n = assets - m;

        a.forceApprove(address(marginEngine), m);
        marginEngine.deposit(address(market), address(this), m);
        a.forceApprove(address(source), n);
        uint256 sharesBefore = source.balanceOf(address(this));
        // slither-disable-next-line unused-return
        source.deposit(n, address(this));
        if (source.balanceOf(address(this)) <= sharesBefore) revert SourceCallFailed();

        uint256 spot = market.currentRate();
        uint256 limit = spot > maxSlippage ? spot - maxSlippage : 0;
        if (_minRate > limit) limit = _minRate;
        // Receive fixed: a negative notional moves the rate down and `limit` is the lowest acceptable end rate.
        // The market reverts unless the whole notional fills above `limit`; since every fill of a receive-fixed
        // trade is at or above the end rate, the locked average rate is >= limit >= minRate.
        // fee is charged from the vault's margin account inside the market; only the fill is needed here
        // slither-disable-start unused-return
        (int256 filled,) = market.trade(-n.toInt256(), limit, block.timestamp);
        // slither-disable-end unused-return
        emit Hedged(depositor, assets, m, filled, market.currentRate());
    }

    function _redeemSource(uint256 maxShares) internal {
        uint256 bal = source.balanceOf(address(this));
        uint256 redeemable = source.maxRedeem(address(this));
        uint256 shares = bal < redeemable ? bal : redeemable;
        if (shares > maxShares) shares = maxShares;
        if (shares == 0) return;
        IERC20 a = IERC20(asset());
        uint256 before = a.balanceOf(address(this));
        // slither-disable-start unused-return,reentrancy-balance
        source.redeem(shares, address(this), address(this));
        // slither-disable-end unused-return,reentrancy-balance
        if (a.balanceOf(address(this)) <= before) revert SourceCallFailed();
    }

    function _depositsOpen(address receiver) internal view returns (bool) {
        if (swapSettled) return false;
        if (block.timestamp + depositCutoff >= market.maturity()) return false;
        if (marginEngine.paused() || marginEngine.marketPaused(address(market))) return false;
        return marginEngine.isAllowed(receiver, IComplianceRegistry.Action.VaultDeposit);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _roundDown() internal pure returns (Math.Rounding) {
        return Math.Rounding.Floor;
    }
}


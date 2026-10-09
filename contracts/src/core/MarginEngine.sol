// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {ISwapMarket} from "../interfaces/ISwapMarket.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";
import {Constants} from "../libraries/Constants.sol";
import {Roles} from "../libraries/Roles.sol";
import {mulDivSigned, floorDiv} from "../libraries/SignedMath18.sol";

/// @title MarginEngine
/// @notice Custodies stablecoin margin (isolated per market and account), values positions, enforces initial and
///         maintenance requirements, runs the daily mark-to-market, and settles cashflows. Also the role authority
///         (AccessControl) and global pause switch for every market clone.
/// @dev Valuation of an account at time t with time-to-maturity tau and mark rate m:
///        N     = varShares * I(t)                      (current variable notional incl. accrued floating)
///        MTM   = N * (1 + m * tau) + fixedCash          (expected cashflow at maturity)
///        req   = (|N| + LP worst case) * shock * max(tau, minTau) + minMargin
///      Liquidation uses the TWAP mark (manipulation resistant); new risk must clear IM under BOTH mark and spot.
contract MarginEngine is IMarginEngine, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct MarketInfo {
        bool registered;
        RiskParams risk;
        uint256 markRate;
        uint256 markTime;
        uint256 markCumulative;
        uint256 lpFeePool;
    }

    IERC20 public immutable override token;
    IOracleAdapter public oracleAdapter;
    IComplianceRegistry public compliance;
    address public feeCollector;

    uint256 public insuranceFund;
    uint256 public deficit;

    mapping(address market => MarketInfo) private _markets;
    mapping(address market => mapping(address account => uint256)) private _margin;
    mapping(address market => bool) public override marketPaused;

    event MarketRegistered(address indexed market, RiskParams risk);
    event RiskParamsUpdated(address indexed market, RiskParams risk);
    event MarginDeposited(address indexed market, address indexed account, address indexed from, uint256 amount);
    event MarginWithdrawn(address indexed market, address indexed account, address indexed to, uint256 amount);
    event FeeCharged(address indexed market, address indexed account, uint256 fee, uint256 protocolFee);
    event LpFeeCredited(address indexed market, address indexed account, uint256 amount);
    event AccountSettled(address indexed market, address indexed account, int256 cashflow, uint256 finalMargin);
    event BadDebt(address indexed market, address indexed account, uint256 shortfall, uint256 coveredByInsurance);
    event LiquidationReward(address indexed market, address indexed account, address indexed liquidator, uint256 r);
    event MarkToMarket(address indexed market, uint256 markRate, uint256 timestamp);
    event InsuranceFunded(address indexed from, uint256 amount);
    event InsuranceWithdrawn(address indexed to, uint256 amount);
    event MarketPauseSet(address indexed market, bool paused);
    event OracleAdapterUpdated(address adapter);
    event ComplianceUpdated(address registry);
    event FeeCollectorUpdated(address collector);

    error UnknownMarket();
    error OnlyMarket();
    error InvalidParams();
    error InsufficientMargin();
    error BelowInitialMargin(int256 equity, uint256 requirement);
    error SettlementRequired();
    error NotAllowed();
    error MarketIsPaused();
    error ZeroAmount();

    modifier onlyMarket() {
        if (!_markets[msg.sender].registered) revert OnlyMarket();
        _;
    }

    constructor(IERC20 token_, address admin, address guardian) {
        if (address(token_) == address(0) || admin == address(0)) revert InvalidParams();
        token = token_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (guardian != address(0)) _grantRole(Roles.GUARDIAN_ROLE, guardian);
    }

    // ------------------------------------------------------------------------------------------ user actions

    /// @notice Deposit margin for `account` in `market` (anyone may top up anyone). Allowed while paused.
    function deposit(address market, address account, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!_markets[market].registered) revert UnknownMarket();
        if (!isAllowed(account, IComplianceRegistry.Action.DepositMargin)) revert NotAllowed();
        _margin[market][account] += amount;
        emit MarginDeposited(market, account, msg.sender, amount);
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw free margin. Before maturity the account must stay above initial margin; after maturity any
    ///         open position must be settled first.
    function withdraw(address market, uint256 amount, address to) external override nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (!_markets[market].registered) revert UnknownMarket();
        if (marketPaused[market]) revert MarketIsPaused();
        uint256 m = _margin[market][msg.sender];
        if (amount > m) revert InsufficientMargin();

        ISwapMarket.AccountState memory s = ISwapMarket(market).accountState(msg.sender);
        bool matured = block.timestamp >= ISwapMarket(market).maturity();
        if (matured && s.hasPosition && !ISwapMarket(market).settled(msg.sender)) revert SettlementRequired();

        _margin[market][msg.sender] = m - amount;
        if (!matured && s.hasPosition) {
            Health memory h = _health(market, msg.sender, s, true);
            if (h.equity < h.initialRequirement.toInt256()) revert BelowInitialMargin(h.equity, h.initialRequirement);
        }
        emit MarginWithdrawn(market, msg.sender, to, amount);
        token.safeTransfer(to, amount);
    }

    /// @notice Anyone can add to the insurance fund that absorbs bad debt at settlement.
    function fundInsurance(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        insuranceFund += amount;
        emit InsuranceFunded(msg.sender, amount);
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Permissionless daily mark-to-market: record the vAMM TWAP since the previous mark.
    function poke(address market) external {
        MarketInfo storage info = _markets[market];
        if (!info.registered) revert UnknownMarket();
        _mark(market, info);
    }

    function pokeIfDue(address market) external override {
        MarketInfo storage info = _markets[market];
        if (!info.registered) revert UnknownMarket();
        if (block.timestamp >= info.markTime + info.risk.markInterval) _mark(market, info);
    }

    // ------------------------------------------------------------------------------------------ market hooks

    function chargeFee(address account, uint256 fee, uint256 protocolFee) external override onlyMarket {
        if (fee == 0) return;
        uint256 m = _margin[msg.sender][account];
        if (fee > m) revert InsufficientMargin();
        _margin[msg.sender][account] = m - fee;
        uint256 toProtocol = protocolFee > fee ? fee : protocolFee;
        _markets[msg.sender].lpFeePool += fee - toProtocol;
        emit FeeCharged(msg.sender, account, fee, toProtocol);
        if (toProtocol > 0) {
            if (feeCollector == address(0)) insuranceFund += toProtocol;
            else token.safeTransfer(feeCollector, toProtocol);
        }
    }

    function creditLpFee(address account, uint256 amount) external override onlyMarket {
        MarketInfo storage info = _markets[msg.sender];
        uint256 amt = amount > info.lpFeePool ? info.lpFeePool : amount;
        info.lpFeePool -= amt;
        _margin[msg.sender][account] += amt;
        emit LpFeeCredited(msg.sender, account, amt);
    }

    function checkInitialMargin(address account) external view override onlyMarket {
        ISwapMarket.AccountState memory s = ISwapMarket(msg.sender).accountState(account);
        if (!s.hasPosition) return;
        Health memory h = _health(msg.sender, account, s, true);
        if (h.equity < h.initialRequirement.toInt256()) revert BelowInitialMargin(h.equity, h.initialRequirement);
    }

    function settleAccount(address account, int256 cashflow) external override onlyMarket {
        int256 newMargin = _margin[msg.sender][account].toInt256() + cashflow;
        uint256 finalMargin = 0;
        if (newMargin < 0) {
            uint256 shortfall = uint256(-newMargin);
            uint256 cover = shortfall > insuranceFund ? insuranceFund : shortfall;
            insuranceFund -= cover;
            deficit += shortfall - cover;
            emit BadDebt(msg.sender, account, shortfall, cover);
        } else {
            finalMargin = uint256(newMargin);
        }
        _margin[msg.sender][account] = finalMargin;
        emit AccountSettled(msg.sender, account, cashflow, finalMargin);
    }

    function payLiquidationReward(address account, address liquidator, uint256 maintenanceBefore)
        external
        override
        onlyMarket
        returns (uint256 reward)
    {
        reward = mulDiv(maintenanceBefore, _markets[msg.sender].risk.liquidationRewardBps, Constants.BPS);
        uint256 m = _margin[msg.sender][account];
        if (reward > m) reward = m;
        _margin[msg.sender][account] = m - reward;
        emit LiquidationReward(msg.sender, account, liquidator, reward);
        if (reward > 0) token.safeTransfer(liquidator, reward);
    }

    // ------------------------------------------------------------------------------------------ views

    function marginOf(address market, address account) external view override returns (uint256) {
        return _margin[market][account];
    }

    function marketInfo(address market) external view returns (MarketInfo memory) {
        return _markets[market];
    }

    /// @notice Health at the mark rate (the basis for liquidation).
    function health(address market, address account) external view override returns (Health memory) {
        ISwapMarket.AccountState memory s = ISwapMarket(market).accountState(account);
        return _health(market, account, s, false);
    }

    /// @notice Health under the conservative basis used for new risk (worse of mark and spot valuation).
    function initialHealth(address market, address account) external view returns (Health memory) {
        ISwapMarket.AccountState memory s = ISwapMarket(market).accountState(account);
        return _health(market, account, s, true);
    }

    function isLiquidatable(address market, address account) external view override returns (bool) {
        if (block.timestamp >= ISwapMarket(market).maturity()) return false;
        ISwapMarket.AccountState memory s = ISwapMarket(market).accountState(account);
        if (!s.hasPosition) return false;
        Health memory h = _health(market, account, s, false);
        // Nothing left to unwind (only locked fixed cash): liquidating again would just let keepers skim the
        // margin that must absorb the shortfall at settlement.
        if (h.exposure == 0) return false;
        return h.equity < h.maintenanceRequirement.toInt256();
    }

    function isAllowed(address account, IComplianceRegistry.Action action) public view override returns (bool) {
        IComplianceRegistry c = compliance;
        return address(c) == address(0) || c.isAllowed(account, action);
    }

    function collateralHealthy() external view override returns (bool) {
        IOracleAdapter a = oracleAdapter;
        if (address(a) == address(0)) return true;
        try a.isCollateralHealthy(address(token)) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function paused() public view override(IMarginEngine, Pausable) returns (bool) {
        return Pausable.paused();
    }

    function hasRole(bytes32 role, address account) public view override(IMarginEngine, AccessControl) returns (bool) {
        return AccessControl.hasRole(role, account);
    }

    // ------------------------------------------------------------------------------------------ admin

    function registerMarket(address market, RiskParams calldata risk) external onlyRole(Roles.FACTORY_ROLE) {
        _validateRisk(risk);
        MarketInfo storage info = _markets[market];
        info.registered = true;
        info.risk = risk;
        emit MarketRegistered(market, risk);
        _mark(market, info);
    }

    function setRiskParams(address market, RiskParams calldata risk) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_markets[market].registered) revert UnknownMarket();
        _validateRisk(risk);
        _markets[market].risk = risk;
        emit RiskParamsUpdated(market, risk);
    }

    function setOracleAdapter(IOracleAdapter adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        oracleAdapter = adapter;
        emit OracleAdapterUpdated(address(adapter));
    }

    function setCompliance(IComplianceRegistry registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = registry;
        emit ComplianceUpdated(address(registry));
    }

    function setFeeCollector(address collector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeCollector = collector;
        emit FeeCollectorUpdated(collector);
    }

    /// @notice Governance may use the insurance fund (e.g. to recapitalise a deficit). Timelocked.
    function withdrawInsurance(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount > insuranceFund) revert InsufficientMargin();
        insuranceFund -= amount;
        emit InsuranceWithdrawn(to, amount);
        token.safeTransfer(to, amount);
    }

    function pause() external onlyRole(Roles.GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function pauseMarket(address market) external onlyRole(Roles.GUARDIAN_ROLE) {
        marketPaused[market] = true;
        emit MarketPauseSet(market, true);
    }

    function unpauseMarket(address market) external onlyRole(DEFAULT_ADMIN_ROLE) {
        marketPaused[market] = false;
        emit MarketPauseSet(market, false);
    }

    // ------------------------------------------------------------------------------------------ internal

    function _mark(address market, MarketInfo storage info) internal {
        (uint256 cum, uint256 ts) = ISwapMarket(market).observe();
        uint256 r;
        if (info.markTime == 0 || ts <= info.markTime) {
            r = ISwapMarket(market).currentRate();
        } else {
            r = (cum - info.markCumulative) / (ts - info.markTime);
        }
        info.markRate = r;
        info.markTime = ts;
        info.markCumulative = cum;
        emit MarkToMarket(market, r, ts);
    }

    function _health(address market, address account, ISwapMarket.AccountState memory s, bool conservative)
        internal
        view
        returns (Health memory h)
    {
        MarketInfo storage info = _markets[market];
        int256 margin = (_margin[market][account] + s.lpFeesOwed).toInt256();
        if (!s.hasPosition) {
            h.equity = margin;
            return h;
        }
        ISwapMarket m = ISwapMarket(market);
        uint256 index = m.oracle().currentIndex();
        uint256 maturity_ = m.maturity();
        uint256 tauSec = block.timestamp >= maturity_ ? 0 : maturity_ - block.timestamp;
        uint256 tauWad = mulDiv(tauSec, Constants.WAD, Constants.YEAR);

        int256 varNotional = mulDivSigned(s.varSharesX18, index, Constants.WAD * Constants.X18);
        int256 value = _value(varNotional, s.fixedCashX18, info.markRate, tauWad);
        if (conservative) {
            int256 spotValue = _value(varNotional, s.fixedCashX18, m.currentRate(), tauWad);
            if (spotValue < value) value = spotValue;
        }
        h.equity = margin + value;
        h.exposure = SignedMath.abs(varNotional) + s.lpUnfilledNotional;

        RiskParams storage risk = info.risk;
        uint256 tauEff = tauSec < risk.minTau ? risk.minTau : tauSec;
        uint256 tauEffWad = mulDiv(tauEff, Constants.WAD, Constants.YEAR);
        h.initialRequirement = mulDiv(h.exposure, mulDiv(risk.imShock, tauEffWad, Constants.WAD), Constants.WAD)
            + risk.minMargin;
        h.maintenanceRequirement = mulDiv(h.exposure, mulDiv(risk.mmShock, tauEffWad, Constants.WAD), Constants.WAD)
            + risk.minMargin / 2;
    }

    /// @dev Expected maturity cashflow: N * (1 + rate * tau) + fixedCash, in token units (floored).
    function _value(int256 varNotional, int256 fixedCashX18, uint256 rate, uint256 tauWad)
        internal
        pure
        returns (int256)
    {
        int256 expectedVar = mulDivSigned(varNotional, Constants.WAD + mulDiv(rate, tauWad, Constants.WAD), Constants.WAD);
        return expectedVar + floorDiv(fixedCashX18, Constants.X18);
    }

    function _validateRisk(RiskParams calldata r) internal pure {
        if (
            r.mmShock == 0 || r.imShock < r.mmShock || r.imShock > 1e18 || r.liquidationRewardBps > 5_000
                || r.markInterval == 0 || r.markInterval > 7 days || r.minTau > 365 days
        ) revert InvalidParams();
    }
}

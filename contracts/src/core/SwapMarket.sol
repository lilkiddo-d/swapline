// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {RateVAMM} from "./RateVAMM.sol";
import {LPPositions} from "./LPPositions.sol";
import {IRateOracle} from "../interfaces/IRateOracle.sol";
import {ISwapMarket} from "../interfaces/ISwapMarket.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";
import {Constants} from "../libraries/Constants.sol";
import {Roles} from "../libraries/Roles.sol";
import {mulDivSigned, floorDiv} from "../libraries/SignedMath18.sol";

/// @title SwapMarket
/// @notice One interest-rate swap market: a rate source (via its RateOracle) and a fixed maturity.
/// @dev Accounting model. Every account holds two signed balances (both ×1e18 precision):
///        varSharesX18  = sum(dv_i / I(t_i))            — variable leg, in "index shares"
///        fixedCashX18  = sum(-dv_i * (1 + r_i * tau_i)) — fixed leg plus notional exchange
///      where dv > 0 means the account receives floating (pay-fixed). At maturity T the cashflow is
///        cash = varShares * I(T) + fixedCash
///      which equals sum(dv_i * (I(T)/I(t_i) - 1) - dv_i * r_i * tau_i): floating realised from each trade's index
///      to maturity minus the fixed leg. The map is linear, so the traders' and LPs' balances cancel exactly and
///      total settlement cashflow is zero up to rounding (always in the protocol's favour).
contract SwapMarket is ISwapMarket, Initializable, ReentrancyGuard {
    using SafeCast for uint256;
    using SafeCast for int256;

    struct MarketParams {
        uint256 feeRate; // annualised fee on traded notional, 18 decimals (e.g. 0.002e18 = 20bp/yr)
        uint256 protocolFeeBps; // share of fees to the protocol (rest to LPs)
        uint256 maxOpenInterestBps; // gross open interest cap relative to the source's TVL (0 = uncapped)
        uint256 tradeCutoff; // trading closes this many seconds before maturity
    }

    struct Account {
        int256 varSharesX18;
        int256 fixedCashX18;
        bool settled;
    }

    IMarginEngine public marginEngine;
    RateVAMM public vammContract;
    LPPositions public lpPositions;
    IRateOracle public override oracle;
    uint256 public override maturity;
    uint256 public startTime;
    MarketParams public params;

    mapping(address => Account) private _accounts;
    /// @notice Gross variable exposure across all accounts, in index shares ×1e18.
    uint256 public grossVarSharesX18;
    uint256 public settlementIndex;

    event Trade(
        address indexed account,
        int256 notional,
        uint256 avgRate,
        uint256 endRate,
        uint256 fee,
        int256 varSharesX18,
        int256 fixedCashX18
    );
    event LiquidityChanged(address indexed account, int24 lower, int24 upper, int128 delta);
    event LpExposureFolded(address indexed account, int256 varSharesX18, int256 fixedCashX18, uint256 fees);
    event Settled(address indexed account, int256 cashflow, uint256 settlementIndex);
    event SettlementIndexSet(uint256 index, uint256 maturity);
    event Liquidated(address indexed account, address indexed liquidator, int256 unwound, uint256 reward);
    event ParamsUpdated(MarketParams params);

    error NotAdmin();
    error MarketPaused();
    error Expired();
    error NotMatured();
    error DeadlinePassed();
    error NotAllowed();
    error OracleUnhealthy();
    error CollateralUnhealthy();
    error InsufficientLiquidity(int256 requested, int256 filled);
    error OpenInterestCap();
    error AlreadySettled();
    error NotLiquidator();
    error NotLiquidatable();
    error SettlementPending();
    error InvalidParams();
    error ZeroAmount();

    modifier onlyAdmin() {
        if (!marginEngine.hasRole(0x00, msg.sender)) revert NotAdmin();
        _;
    }

    modifier whenActive() {
        if (marginEngine.paused() || marginEngine.marketPaused(address(this))) revert MarketPaused();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        IMarginEngine marginEngine_,
        RateVAMM vamm_,
        LPPositions lpPositions_,
        IRateOracle oracle_,
        uint256 maturity_,
        MarketParams calldata params_
    ) external initializer {
        if (maturity_ <= block.timestamp) revert InvalidParams();
        marginEngine = marginEngine_;
        vammContract = vamm_;
        lpPositions = lpPositions_;
        oracle = oracle_;
        maturity = maturity_;
        startTime = block.timestamp;
        _setParams(params_);
    }

    // ------------------------------------------------------------------------------------------ trading

    /// @notice Trade variable notional against the vAMM.
    /// @param notional > 0: pay fixed / receive floating. < 0: receive fixed / pay floating. Token units.
    /// @param rateLimit Worst acceptable fixed rate after the trade (max for pay-fixed, min for receive-fixed).
    function trade(int256 notional, uint256 rateLimit, uint256 deadline)
        external
        nonReentrant
        whenActive
        returns (int256 filled, uint256 fee)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (!marginEngine.isAllowed(msg.sender, IComplianceRegistry.Action.Trade)) revert NotAllowed();
        (filled, fee) = _trade(msg.sender, notional, rateLimit, false);
    }

    /// @notice Provide liquidity over [lower, upper) ticks (1 tick = 1bp). Requires margin for the worst case.
    function mint(int24 lower, int24 upper, uint128 liquidityAmount) external nonReentrant whenActive {
        if (liquidityAmount == 0) revert ZeroAmount();
        _checkOpen();
        if (!marginEngine.isAllowed(msg.sender, IComplianceRegistry.Action.ProvideLiquidity)) revert NotAllowed();
        if (!oracle.isHealthy()) revert OracleUnhealthy();
        if (!marginEngine.collateralHealthy()) revert CollateralUnhealthy();
        marginEngine.pokeIfDue(address(this));
        _modifyLiquidity(msg.sender, lower, upper, int128(liquidityAmount));
        marginEngine.checkInitialMargin(msg.sender);
    }

    /// @notice Remove liquidity. Always risk-reducing, so no margin check (oracle health not required).
    function burn(int24 lower, int24 upper, uint128 liquidityAmount) external nonReentrant whenActive {
        if (liquidityAmount == 0) revert ZeroAmount();
        _modifyLiquidity(msg.sender, lower, upper, -int128(liquidityAmount));
    }

    /// @notice Fold accrued LP exposure and fees into the account without changing liquidity.
    function collect(int24 lower, int24 upper) external nonReentrant {
        _modifyLiquidity(msg.sender, lower, upper, 0);
    }

    // ------------------------------------------------------------------------------------------ settlement

    // slither-disable-start reentrancy-no-eth
    // Callees are protocol contracts fixed at initialisation (RateVAMM clone, RateOracle, MarginEngine) and every
    // external entry point is nonReentrant, so the post-call writes below cannot be re-entered.
    /// @notice Settle an account after maturity: net fixed vs realised floating into margin. Permissionless.
    function settle(address account) external nonReentrant returns (int256 cashflow) {
        if (block.timestamp < maturity) revert NotMatured();
        Account storage a = _accounts[account];
        if (a.settled) revert AlreadySettled();
        uint256 idx = _settlementIndex();
        _closeAllLp(account);

        // effects
        int256 v = a.varSharesX18;
        int256 f = a.fixedCashX18;
        _setBalances(account, 0, 0);
        a.settled = true;
        cashflow = floorDiv(mulDivSigned(v, idx, Constants.WAD) + f, Constants.X18);
        emit Settled(account, cashflow, idx);

        // interaction
        marginEngine.settleAccount(account, cashflow);
    }
    // slither-disable-end reentrancy-no-eth

    // slither-disable-start reentrancy-no-eth
    // Callees are protocol contracts fixed at initialisation (RateVAMM clone, RateOracle, MarginEngine) and every
    // external entry point is nonReentrant, so the post-call writes below cannot be re-entered.
    /// @notice Settlement index I(T), fixed once for all accounts. Snapshots the oracle if needed.
    function _settlementIndex() internal returns (uint256 idx) {
        idx = settlementIndex;
        if (idx != 0) return idx;
        if (oracle.latestObservation().timestamp < maturity) {
            // return value ignored on purpose: the observation timestamp is re-checked right below
            // slither-disable-start unused-return
            oracle.snapshot();
            // slither-disable-end unused-return
            if (oracle.latestObservation().timestamp < maturity) revert SettlementPending();
        }
        idx = oracle.indexAt(maturity);
        settlementIndex = idx;
        emit SettlementIndexSet(idx, maturity);
    }
    // slither-disable-end reentrancy-no-eth

    // ------------------------------------------------------------------------------------------ liquidation

    // slither-disable-start reentrancy-no-eth
    // Callees are protocol contracts fixed at initialisation (RateVAMM clone, RateOracle, MarginEngine) and every
    // external entry point is nonReentrant, so the post-call writes below cannot be re-entered.
    /// @notice Unwind an account below maintenance margin. Callable only by the Liquidator contract.
    function liquidate(address account, address liquidator, uint256 rateBand)
        external
        override
        nonReentrant
        whenActive
        returns (uint256 reward)
    {
        if (!marginEngine.hasRole(Roles.LIQUIDATOR_ROLE, msg.sender)) revert NotLiquidator();
        if (block.timestamp >= maturity) revert Expired();
        if (!marginEngine.isLiquidatable(address(this), account)) revert NotLiquidatable();
        uint256 mmBefore = marginEngine.health(address(this), account).maintenanceRequirement;

        _closeAllLp(account);
        int256 unwound = 0;
        int256 vs = _accounts[account].varSharesX18;
        if (vs != 0) {
            uint256 index = oracle.currentIndex();
            int256 notional = -mulDivSigned(vs, index, Constants.WAD * Constants.X18);
            if (notional != 0) {
                uint256 r = vammContract.rate();
                uint256 limit = notional > 0 ? _min(r + rateBand, vammContract.MAX_RATE()) : (r > rateBand ? r - rateBand : 0);
                if (limit != r) (unwound,) = _trade(account, notional, limit, true);
            }
        }
        reward = marginEngine.payLiquidationReward(account, liquidator, mmBefore);
        emit Liquidated(account, liquidator, unwound, reward);
    }
    // slither-disable-end reentrancy-no-eth

    // ------------------------------------------------------------------------------------------ admin

    function setParams(MarketParams calldata params_) external onlyAdmin {
        _setParams(params_);
    }

    // ------------------------------------------------------------------------------------------ views

    function vamm() external view override returns (address) {
        return address(vammContract);
    }

    function currentRate() external view override returns (uint256) {
        return vammContract.rate();
    }

    function observe() external view override returns (uint256, uint256) {
        return vammContract.observe();
    }

    function settled(address account) external view override returns (bool) {
        return _accounts[account].settled;
    }

    function rawBalances(address account) external view returns (int256 varSharesX18, int256 fixedCashX18) {
        Account storage a = _accounts[account];
        return (a.varSharesX18, a.fixedCashX18);
    }

    /// @notice Full account state including LP exposure accrued since the last fold (bounded: <= 8 ranges).
    function accountState(address account) public view override returns (AccountState memory s) {
        Account storage a = _accounts[account];
        s.varSharesX18 = a.varSharesX18;
        s.fixedCashX18 = a.fixedCashX18;
        LPPositions.Position[] memory list = lpPositions.positionsOf(address(this), account);
        for (uint256 i; i < list.length; ++i) {
            RateVAMM.GrowthInside memory inside = vammContract.growthInside(list[i].lower, list[i].upper);
            LPPositions.Accrued memory acc = lpPositions.accrued(list[i], inside);
            s.varSharesX18 += acc.varSharesX18;
            s.fixedCashX18 += acc.fixedCashX18;
            s.lpFeesOwed += acc.feesX18 / Constants.X18;
            uint256 width = uint256(int256(list[i].upper - list[i].lower)) * vammContract.TICK_SIZE();
            s.lpUnfilledNotional += mulDiv(uint256(list[i].liquidity), width, Constants.WAD);
        }
        s.hasPosition = s.varSharesX18 != 0 || s.fixedCashX18 != 0 || list.length > 0;
    }

    /// @notice Quote a trade without executing it (static call simulation is the canonical quote path; this is a
    ///         cheap estimate of the time-to-maturity in years used for pricing).
    function tau() public view returns (uint256) {
        return block.timestamp >= maturity ? 0 : mulDiv(maturity - block.timestamp, Constants.WAD, Constants.YEAR);
    }

    // ------------------------------------------------------------------------------------------ internal

    // slither-disable-start reentrancy-no-eth
    // Callees are protocol contracts fixed at initialisation (RateVAMM clone, RateOracle, MarginEngine) and every
    // external entry point is nonReentrant, so the post-call writes below cannot be re-entered.
    function _trade(address account, int256 notional, uint256 rateLimit, bool isLiquidation)
        internal
        returns (int256 filled, uint256 fee)
    {
        if (notional == 0) revert ZeroAmount();
        if (!isLiquidation) {
            _checkOpen();
            marginEngine.pokeIfDue(address(this));
        }

        Account storage a = _accounts[account];
        int256 vsBefore = a.varSharesX18;
        uint256 index = oracle.currentIndex();

        RateVAMM.SwapResult memory res = vammContract.swap(
            RateVAMM.SwapParams({
                amount: notional,
                rateLimit: rateLimit,
                index: index,
                tau: tau(),
                feeRate: params.feeRate,
                protocolFeeBps: params.protocolFeeBps
            })
        );
        filled = res.filled;
        if (!isLiquidation && filled != notional) revert InsufficientLiquidity(notional, filled);
        if (filled == 0) return (0, 0);

        int256 vsAfter = vsBefore + res.traderVarSharesX18;
        _setBalances(account, vsAfter, a.fixedCashX18 + res.traderFixedCashX18);

        fee = _ceilDiv(res.feeX18, Constants.X18);
        uint256 protocolFee = res.protocolFeeX18 / Constants.X18;
        if (isLiquidation) {
            // never let fees block a liquidation: cap at remaining margin (LP fee claims are capped by the pool)
            uint256 m = marginEngine.marginOf(address(this), account);
            if (fee > m) fee = m;
            if (protocolFee > fee) protocolFee = fee;
        }
        uint256 avgRate = _avgRate(res, filled);
        emit Trade(account, filled, avgRate, res.endRate, fee, res.traderVarSharesX18, res.traderFixedCashX18);

        marginEngine.chargeFee(account, fee, protocolFee);

        bool riskIncreasing = SignedMath.abs(vsAfter) > SignedMath.abs(vsBefore) || (vsBefore > 0 && vsAfter < 0)
            || (vsBefore < 0 && vsAfter > 0);
        if (riskIncreasing && !isLiquidation) {
            if (!oracle.isHealthy()) revert OracleUnhealthy();
            if (!marginEngine.collateralHealthy()) revert CollateralUnhealthy();
            _checkOpenInterest(index);
            marginEngine.checkInitialMargin(account);
        }
    }
    // slither-disable-end reentrancy-no-eth

    function _modifyLiquidity(address account, int24 lower, int24 upper, int128 delta) internal {
        if (block.timestamp >= maturity && delta > 0) revert Expired();
        RateVAMM.GrowthInside memory inside = vammContract.updateLiquidity(lower, upper, delta);
        LPPositions.Accrued memory acc = lpPositions.update(account, lower, upper, delta, inside);
        _fold(account, acc);
        emit LiquidityChanged(account, lower, upper, delta);
    }

    function _closeAllLp(address account) internal {
        LPPositions.Position[] memory list = lpPositions.positionsOf(address(this), account);
        for (uint256 i; i < list.length; ++i) {
            _modifyLiquidity(account, list[i].lower, list[i].upper, -int128(list[i].liquidity));
        }
    }

    function _fold(address account, LPPositions.Accrued memory acc) internal {
        Account storage a = _accounts[account];
        if (acc.varSharesX18 != 0 || acc.fixedCashX18 != 0) {
            _setBalances(account, a.varSharesX18 + acc.varSharesX18, a.fixedCashX18 + acc.fixedCashX18);
        }
        uint256 fees = acc.feesX18 / Constants.X18;
        emit LpExposureFolded(account, acc.varSharesX18, acc.fixedCashX18, fees);
        if (fees > 0) marginEngine.creditLpFee(account, fees);
    }

    function _setBalances(address account, int256 vs, int256 fc) internal {
        Account storage a = _accounts[account];
        uint256 oldAbs = SignedMath.abs(a.varSharesX18);
        uint256 newAbs = SignedMath.abs(vs);
        grossVarSharesX18 = grossVarSharesX18 + newAbs - oldAbs;
        a.varSharesX18 = vs;
        a.fixedCashX18 = fc;
    }

    function _checkOpenInterest(uint256 index) internal view {
        uint256 capBps = params.maxOpenInterestBps;
        if (capBps == 0) return;
        uint256 tvl = 0;
        try oracle.source().totalValue() returns (uint256 v) {
            tvl = v;
        } catch {
            revert OpenInterestCap();
        }
        uint256 oi = mulDiv(grossVarSharesX18, index, Constants.WAD * Constants.X18);
        if (oi > mulDiv(tvl, capBps, Constants.BPS)) revert OpenInterestCap();
    }

    function _checkOpen() internal view {
        if (block.timestamp + params.tradeCutoff >= maturity) revert Expired();
    }

    function _setParams(MarketParams calldata p) internal {
        if (p.feeRate > 0.05e18 || p.protocolFeeBps > Constants.BPS || p.maxOpenInterestBps > 100 * Constants.BPS) {
            revert InvalidParams();
        }
        params = p;
        emit ParamsUpdated(p);
    }

    function _avgRate(RateVAMM.SwapResult memory res, int256 filled) internal view returns (uint256) {
        // fixedCash = -(filled + filled*avg*tau) for pay-fixed  => avg = (|fixedCash| - |filled|) / (|filled| * tau)
        uint256 t = tau();
        uint256 absFilled = SignedMath.abs(filled);
        uint256 absFixed = SignedMath.abs(res.traderFixedCashX18);
        uint256 base = absFilled * Constants.X18;
        if (t == 0 || absFixed <= base) return res.endRate;
        return mulDiv(absFixed - base, Constants.WAD * Constants.WAD, base * t);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}


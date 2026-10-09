// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {TickBitmap} from "../libraries/TickBitmap.sol";
import {Constants} from "../libraries/Constants.sol";

/// @title RateVAMM
/// @notice Virtual AMM quoting the fixed rate for one market (rate source + maturity). No tokens are held here.
/// @dev Price = fixed rate (18 decimals). Ticks are 1bp wide (tick t <-> rate t * 1e14), range [0, 100%].
///      LPs supply *linear-density* liquidity L over a rate range [lower, upper): moving the rate by dr inside the
///      range fills L * dr variable notional, at an average fixed rate of the midpoint. Hence for a step r0 -> r1:
///          notional = L * |r1 - r0|,  fixed rate paid = (r0 + r1) / 2.
///      Positions accrue in final settlement units (variable shares and fixed cash, both ×1e18) via per-liquidity
///      growth accumulators with Uniswap-v3-style "outside" bookkeeping, so LP exposure is O(1) to compute.
///      Every swap is bounded by MAX_CROSSINGS tick crossings.
contract RateVAMM is Initializable {
    using TickBitmap for mapping(int16 => uint256);
    using SafeCast for uint256;
    using SafeCast for int256;

    struct TickInfo {
        uint128 liquidityGross;
        int128 liquidityNet;
        uint256 feeGrowthOutside;
        int256 varGrowthOutside;
        int256 fixedGrowthOutside;
    }

    struct SwapParams {
        /// @dev Variable notional the trader takes: > 0 pay-fixed (receive variable, rate moves up), < 0 receive-fixed.
        int256 amount;
        uint256 rateLimit;
        uint256 index; // oracle index at trade time, 18 decimals
        uint256 tau; // time to maturity in years, 18 decimals
        uint256 feeRate; // annualised fee on notional, 18 decimals
        uint256 protocolFeeBps; // share of the fee kept by the protocol
    }

    struct SwapResult {
        int256 filled; // signed variable notional the trader received (token units)
        int256 traderVarSharesX18;
        int256 traderFixedCashX18;
        uint256 feeX18; // total fee charged to the trader, token units ×1e18
        uint256 protocolFeeX18;
        uint256 endRate;
        uint256 crossings;
    }

    struct GrowthInside {
        uint256 fee;
        int256 var_;
        int256 fixed_;
    }

    int24 public constant MAX_TICK = 10_000; // 100%
    uint256 public constant TICK_SIZE = 1e14; // 1bp
    uint256 public constant MAX_RATE = 1e18;
    uint256 public constant MAX_CROSSINGS = 64;
    uint256 private constant Q = 1e18; // growth accumulator scale

    address public market;
    int24 public tickSpacing;

    uint256 public rate;
    int24 public tick;
    uint128 public liquidity;

    uint256 public feeGrowthGlobal;
    int256 public varGrowthGlobal;
    int256 public fixedGrowthGlobal;

    uint256 public rateCumulative;
    uint256 public lastObservation;

    mapping(int24 => TickInfo) public ticks;
    mapping(int16 => uint256) public tickBitmap;

    event Swap(int256 filled, uint256 startRate, uint256 endRate, uint256 feeX18, uint256 crossings);
    event LiquidityUpdated(int24 indexed lower, int24 indexed upper, int128 delta, uint128 activeLiquidity);
    event TickCrossed(int24 indexed tick, uint128 activeLiquidity);

    error OnlyMarket();
    error InvalidTicks();
    error InvalidRateLimit();
    error ZeroAmount();
    error InvalidSpacing();
    error LiquidityUnderflow();

    modifier onlyMarket() {
        if (msg.sender != market) revert OnlyMarket();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address market_, int24 tickSpacing_, uint256 initialRate) external initializer {
        if (tickSpacing_ < 10 || tickSpacing_ > 1000 || MAX_TICK % tickSpacing_ != 0) revert InvalidSpacing();
        if (initialRate > MAX_RATE) revert InvalidRateLimit();
        market = market_;
        tickSpacing = tickSpacing_;
        rate = initialRate;
        tick = int24(uint24(initialRate / TICK_SIZE));
        if (tick > MAX_TICK) tick = MAX_TICK;
        lastObservation = block.timestamp;
    }

    // ------------------------------------------------------------------------------------------ liquidity

    /// @notice Add (delta > 0) or remove (delta < 0) liquidity in [lower, upper). Returns current growth inside.
    function updateLiquidity(int24 lower, int24 upper, int128 delta)
        external
        onlyMarket
        returns (GrowthInside memory inside)
    {
        _checkTicks(lower, upper);
        _accumulate();
        bool clearLower = false;
        bool clearUpper = false;
        if (delta != 0) {
            clearLower = _updateTick(lower, delta, false);
            clearUpper = _updateTick(upper, delta, true);
            if (lower <= tick && tick < upper) {
                liquidity = _addDelta(liquidity, delta);
            }
        }
        // growth must be read BEFORE emptied ticks are cleared (clearing resets their "outside" accumulators)
        inside = growthInside(lower, upper);
        if (clearLower) _clearTick(lower);
        if (clearUpper) _clearTick(upper);
        emit LiquidityUpdated(lower, upper, delta, liquidity);
    }

    function growthInside(int24 lower, int24 upper) public view returns (GrowthInside memory inside) {
        TickInfo storage lo = ticks[lower];
        TickInfo storage hi = ticks[upper];
        int24 t = tick;
        unchecked {
            uint256 feeBelow = t >= lower ? lo.feeGrowthOutside : feeGrowthGlobal - lo.feeGrowthOutside;
            uint256 feeAbove = t < upper ? hi.feeGrowthOutside : feeGrowthGlobal - hi.feeGrowthOutside;
            inside.fee = feeGrowthGlobal - feeBelow - feeAbove;
        }
        int256 varBelow = t >= lower ? lo.varGrowthOutside : varGrowthGlobal - lo.varGrowthOutside;
        int256 varAbove = t < upper ? hi.varGrowthOutside : varGrowthGlobal - hi.varGrowthOutside;
        inside.var_ = varGrowthGlobal - varBelow - varAbove;
        int256 fixBelow = t >= lower ? lo.fixedGrowthOutside : fixedGrowthGlobal - lo.fixedGrowthOutside;
        int256 fixAbove = t < upper ? hi.fixedGrowthOutside : fixedGrowthGlobal - hi.fixedGrowthOutside;
        inside.fixed_ = fixedGrowthGlobal - fixBelow - fixAbove;
    }

    // ------------------------------------------------------------------------------------------ swap

    struct SwapState {
        uint256 remaining;
        uint256 r;
        int24 t;
        uint128 L;
        uint256 filled;
        uint256 fixedNotionalWad; // sum(step * (r0 + r1)) = 2 x sum(step * avgRate), token units x 1e18
        bool up;
    }

    /// @notice Execute a swap against the curve. Partial fills are returned (not reverted); the market decides.
    function swap(SwapParams calldata p) external onlyMarket returns (SwapResult memory res) {
        if (p.amount == 0) revert ZeroAmount();
        SwapState memory st = SwapState({remaining: 0, r: 0, t: 0, L: 0, filled: 0, fixedNotionalWad: 0, up: p.amount > 0});
        uint256 startRate = rate;
        if (st.up ? (p.rateLimit <= startRate || p.rateLimit > MAX_RATE) : p.rateLimit >= startRate) {
            revert InvalidRateLimit();
        }
        _accumulate();

        st.remaining = st.up ? uint256(p.amount) : uint256(-p.amount);
        st.r = startRate;
        st.t = tick;
        st.L = liquidity;

        while (st.remaining > 0 && res.crossings < MAX_CROSSINGS) {
            (bool found, int24 nextTick) = st.up
                ? tickBitmap.nextAbove(st.t, tickSpacing, MAX_TICK)
                : tickBitmap.nextAtOrBelow(st.t, tickSpacing);
            // No initialised tick in this direction => no liquidity beyond: range exhausted.
            if (!found) break;
            uint256 boundary = uint256(uint24(nextTick)) * TICK_SIZE;
            _step(p, st, boundary, res);

            if (st.r == boundary && (st.up || st.remaining > 0 || st.L == 0)) {
                _cross(st, nextTick);
                res.crossings++;
            } else {
                st.t = _tickOf(st.r, st.t, st.up);
            }
            if (st.r == p.rateLimit) break;
        }

        rate = st.r;
        tick = st.t;
        liquidity = st.L;
        _finalise(p, st, res);
        emit Swap(res.filled, startRate, st.r, res.feeX18, res.crossings);
    }

    /// @dev Move the rate toward min/max(boundary, rateLimit), filling up to the remaining notional.
    function _step(SwapParams calldata p, SwapState memory st, uint256 boundary, SwapResult memory res) internal {
        uint256 target = st.up ? (boundary < p.rateLimit ? boundary : p.rateLimit)
            : (boundary > p.rateLimit ? boundary : p.rateLimit);
        if (st.L == 0) {
            st.r = target;
            return;
        }
        uint256 cap = mulDiv(uint256(st.L), st.up ? target - st.r : st.r - target, Constants.WAD);
        uint256 step;
        uint256 newRate;
        if (st.remaining < cap) {
            step = st.remaining;
            uint256 move = mulDiv(step, Constants.WAD, uint256(st.L)) + 1; // round against the trader
            if (st.up) newRate = st.r + move > target ? target : st.r + move;
            else newRate = st.r < target + move ? target : st.r - move;
        } else {
            step = cap;
            newRate = target;
        }
        if (step > 0) {
            // rate sum (= 2 x average) avoids dividing before multiplying; halved once, in _finalise/_accrueStep
            uint256 rateSum = st.r + newRate;
            st.fixedNotionalWad += step * rateSum;
            _accrueStep(p, step, rateSum, st.L, st.up, res);
            st.filled += step;
            st.remaining -= step;
        }
        st.r = newRate;
    }

    function _cross(SwapState memory st, int24 nextTick) internal {
        TickInfo storage info = ticks[nextTick];
        info.feeGrowthOutside = _wrapSub(feeGrowthGlobal, info.feeGrowthOutside);
        info.varGrowthOutside = varGrowthGlobal - info.varGrowthOutside;
        info.fixedGrowthOutside = fixedGrowthGlobal - info.fixedGrowthOutside;
        st.L = st.up ? _addDelta(st.L, info.liquidityNet) : _addDelta(st.L, -info.liquidityNet);
        st.t = st.up ? nextTick : nextTick - 1;
        emit TickCrossed(nextTick, st.L);
    }

    /// @dev Trader legs in settlement units: varShares = filled / index ; fixedCash = -(filled + sum(step*rate)*tau).
    function _finalise(SwapParams calldata p, SwapState memory st, SwapResult memory res) internal pure {
        res.endRate = st.r;
        int256 filledSigned = st.filled.toInt256();
        int256 vs = mulDiv(st.filled, Constants.X18 * Constants.WAD, p.index).toInt256();
        int256 fixedLeg = (st.filled * Constants.X18 + mulDiv(st.fixedNotionalWad, p.tau, 2 * Constants.WAD)).toInt256();
        if (st.up) {
            res.filled = filledSigned;
            res.traderVarSharesX18 = vs;
            res.traderFixedCashX18 = -fixedLeg;
        } else {
            res.filled = -filledSigned;
            res.traderVarSharesX18 = -vs;
            res.traderFixedCashX18 = fixedLeg;
        }
    }

    /// @notice Time-weighted rate accumulator extended to now (for TWAP marks).
    function observe() external view returns (uint256 cumulative, uint256 timestamp) {
        return (rateCumulative + rate * (block.timestamp - lastObservation), block.timestamp);
    }

    // ------------------------------------------------------------------------------------------ internal

    /// @dev LP-side accrual for one step: LPs take the opposite variable leg and receive the fees.
    function _accrueStep(SwapParams calldata p, uint256 step, uint256 rateSum, uint128 L, bool up, SwapResult memory res)
        internal
    {
        uint256 varSharesX18 = mulDiv(step, Constants.X18 * Constants.WAD, p.index);
        uint256 fixedX18 = step * Constants.X18 + mulDiv(step * rateSum, p.tau, 2 * Constants.WAD);
        // LP gets the opposite of the trader
        int256 lpVar = up ? -varSharesX18.toInt256() : varSharesX18.toInt256();
        int256 lpFix = up ? fixedX18.toInt256() : -fixedX18.toInt256();
        varGrowthGlobal += _perLiquidity(lpVar, L);
        fixedGrowthGlobal += _perLiquidity(lpFix, L);

        uint256 feeX18 = mulDiv(step * Constants.X18, mulDiv(p.feeRate, p.tau, Constants.WAD), Constants.WAD);
        uint256 protocolX18 = (feeX18 * p.protocolFeeBps) / Constants.BPS;
        unchecked {
            feeGrowthGlobal += mulDiv(feeX18 - protocolX18, Q, uint256(L));
        }
        res.feeX18 += feeX18;
        res.protocolFeeX18 += protocolX18;
    }

    /// @dev Rounds toward negative infinity so the sum of LP claims never exceeds what traders created.
    function _perLiquidity(int256 v, uint128 L) internal pure returns (int256) {
        if (v >= 0) return mulDiv(uint256(v), Q, uint256(L)).toInt256();
        uint256 a = mulDiv(uint256(-v), Q, uint256(L));
        return -(a + 1).toInt256();
    }

    function _accumulate() internal {
        uint256 dt = block.timestamp - lastObservation;
        if (dt > 0) {
            rateCumulative += rate * dt;
            lastObservation = block.timestamp;
        }
    }

    /// @return emptied True when the tick no longer references any liquidity and must be cleared by the caller.
    function _updateTick(int24 t, int128 delta, bool isUpper) internal returns (bool emptied) {
        TickInfo storage info = ticks[t];
        uint128 grossBefore = info.liquidityGross;
        uint128 grossAfter = _addDelta(grossBefore, delta);
        if (grossBefore == 0 && grossAfter > 0) {
            if (t <= tick) {
                info.feeGrowthOutside = feeGrowthGlobal;
                info.varGrowthOutside = varGrowthGlobal;
                info.fixedGrowthOutside = fixedGrowthGlobal;
            }
            tickBitmap.flip(t, tickSpacing);
        }
        info.liquidityGross = grossAfter;
        info.liquidityNet = isUpper ? info.liquidityNet - delta : info.liquidityNet + delta;
        emptied = grossAfter == 0;
    }

    function _clearTick(int24 t) internal {
        delete ticks[t];
        tickBitmap.flip(t, tickSpacing);
    }

    function _checkTicks(int24 lower, int24 upper) internal view {
        if (lower < 0 || upper > MAX_TICK || lower >= upper || lower % tickSpacing != 0 || upper % tickSpacing != 0) {
            revert InvalidTicks();
        }
    }

    function _tickOf(uint256 r, int24 current, bool up) internal pure returns (int24) {
        int24 t = int24(uint24(r / TICK_SIZE));
        if (t > MAX_TICK) t = MAX_TICK;
        // never move the tick against the swap direction (rounding at boundaries)
        if (up) return t < current ? current : t;
        return t > current ? current : t;
    }

    function _addDelta(uint128 x, int128 delta) internal pure returns (uint128) {
        if (delta >= 0) return x + uint128(delta);
        uint128 d = uint128(-delta);
        if (d > x) revert LiquidityUnderflow();
        return x - d;
    }

    function _wrapSub(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return a - b;
        }
    }
}

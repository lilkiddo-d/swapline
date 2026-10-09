// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {RateVAMM} from "./RateVAMM.sol";
import {Roles} from "../libraries/Roles.sol";

/// @title LPPositions
/// @notice Book of LP range positions for every market. Each position records liquidity and growth-inside
///         checkpoints; accrued swap exposure (variable shares, fixed cash) and fees are computed from the vAMM
///         growth accumulators. Accounts hold at most MAX_POSITIONS ranges per market so margin checks are bounded.
contract LPPositions is AccessControl {
    using SafeCast for uint256;

    uint256 public constant MAX_POSITIONS = 8;
    uint256 private constant Q = 1e18;

    struct Position {
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint256 feeGrowthInsideLast;
        int256 varGrowthInsideLast;
        int256 fixedGrowthInsideLast;
    }

    struct Accrued {
        int256 varSharesX18;
        int256 fixedCashX18;
        uint256 feesX18;
    }

    mapping(address market => bool) public isMarket;
    mapping(address market => mapping(address owner => Position[])) private _positions;

    event MarketRegistered(address indexed market);
    event PositionUpdated(
        address indexed market, address indexed owner, int24 lower, int24 upper, int128 delta, uint128 liquidity
    );

    error OnlyMarket();
    error TooManyPositions();
    error PositionNotFound();
    error InsufficientLiquidity();

    modifier onlyMarket() {
        if (!isMarket[msg.sender]) revert OnlyMarket();
        _;
    }

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function registerMarket(address market) external onlyRole(Roles.FACTORY_ROLE) {
        isMarket[market] = true;
        emit MarketRegistered(market);
    }

    /// @notice Apply a liquidity delta and checkpoint growth. Returns exposure accrued since the last checkpoint.
    function update(
        address owner,
        int24 lower,
        int24 upper,
        int128 delta,
        RateVAMM.GrowthInside memory inside
    ) external onlyMarket returns (Accrued memory acc) {
        Position[] storage list = _positions[msg.sender][owner];
        (bool found, uint256 i) = _find(list, lower, upper);
        if (!found) {
            if (delta <= 0) revert PositionNotFound();
            if (list.length >= MAX_POSITIONS) revert TooManyPositions();
            list.push(
                Position({
                    lower: lower,
                    upper: upper,
                    liquidity: 0,
                    feeGrowthInsideLast: inside.fee,
                    varGrowthInsideLast: inside.var_,
                    fixedGrowthInsideLast: inside.fixed_
                })
            );
            i = list.length - 1;
        }
        Position storage pos = list[i];
        acc = _accrued(pos, inside);
        pos.feeGrowthInsideLast = inside.fee;
        pos.varGrowthInsideLast = inside.var_;
        pos.fixedGrowthInsideLast = inside.fixed_;

        if (delta >= 0) {
            pos.liquidity = pos.liquidity + uint128(delta);
        } else {
            uint128 d = uint128(-delta);
            if (d > pos.liquidity) revert InsufficientLiquidity();
            pos.liquidity = pos.liquidity - d;
        }
        uint128 after_ = pos.liquidity;
        if (after_ == 0) {
            list[i] = list[list.length - 1];
            list.pop();
        }
        emit PositionUpdated(msg.sender, owner, lower, upper, delta, after_);
    }

    // ------------------------------------------------------------------------------------------ views

    function positionsOf(address market, address owner) external view returns (Position[] memory) {
        return _positions[market][owner];
    }

    function positionCount(address market, address owner) external view returns (uint256) {
        return _positions[market][owner].length;
    }

    function liquidityOf(address market, address owner, int24 lower, int24 upper) external view returns (uint128) {
        (bool found, uint256 i) = _find(_positions[market][owner], lower, upper);
        return found ? _positions[market][owner][i].liquidity : 0;
    }

    /// @notice Exposure accrued (not yet folded into account balances) for one stored position.
    function accrued(Position memory pos, RateVAMM.GrowthInside memory inside)
        external
        pure
        returns (Accrued memory)
    {
        return _accrued(pos, inside);
    }

    function _accrued(Position memory pos, RateVAMM.GrowthInside memory inside)
        internal
        pure
        returns (Accrued memory acc)
    {
        if (pos.liquidity == 0) return acc;
        uint256 L = pos.liquidity;
        acc.varSharesX18 = _mulSigned(inside.var_ - pos.varGrowthInsideLast, L);
        acc.fixedCashX18 = _mulSigned(inside.fixed_ - pos.fixedGrowthInsideLast, L);
        uint256 dFee;
        unchecked {
            dFee = inside.fee - pos.feeGrowthInsideLast;
        }
        acc.feesX18 = mulDiv(dFee, L, Q);
    }

    /// @dev growth * L / Q, rounded toward negative infinity.
    function _mulSigned(int256 growth, uint256 L) internal pure returns (int256) {
        if (growth >= 0) return mulDiv(uint256(growth), L, Q).toInt256();
        uint256 a = uint256(-growth);
        uint256 r = mulDiv(a, L, Q);
        if (mulmod(a, L, Q) != 0) r += 1;
        return -r.toInt256();
    }

    function _find(Position[] storage list, int24 lower, int24 upper) internal view returns (bool, uint256) {
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            if (list[i].lower == lower && list[i].upper == upper) return (true, i);
        }
        return (false, 0);
    }
}

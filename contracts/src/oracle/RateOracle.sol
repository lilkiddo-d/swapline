// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IRateOracle} from "../interfaces/IRateOracle.sol";
import {IRateSource} from "../interfaces/IRateSource.sol";
import {Roles} from "../libraries/Roles.sol";
import {Constants} from "../libraries/Constants.sol";

/// @title RateOracle
/// @notice Derives a floating rate for one yield source purely from on-chain exchange-rate growth.
///         Snapshots of the source index are stored in a fixed-size ring buffer.
/// @dev Manipulation resistance: the oracle index is a *chained product of per-period growth factors*, each clamped
///      to `maxRatePerYear`. A donation that inflates the source's share price in one period is therefore discarded
///      beyond the cap permanently, not merely delayed. Decreases are passed through (real losses must reach the
///      floating leg) but flag the source as impaired, which halts new risk on every market using it.
contract RateOracle is IRateOracle, AccessControl {
    uint256 public constant CAPACITY = 1024;

    IRateSource public immutable override source;

    Observation[CAPACITY] private _obs;
    uint256 private _head; // physical slot of the latest observation
    uint256 private _count;

    /// @notice Raw source index at the latest snapshot (unclamped), used to chain growth factors.
    uint256 public lastRawIndex;

    uint256 public minInterval;
    uint256 public maxStaleness;
    uint256 public maxRatePerYear;
    bool public override impaired;

    error InvalidParams();
    error InvalidIndex();
    error TimestampTooOld(uint256 requested, uint256 oldest);
    error TimestampNotObserved(uint256 requested, uint256 latest);
    error InvalidRange();

    constructor(IRateSource source_, address admin, uint256 minInterval_, uint256 maxStaleness_, uint256 maxRatePerYear_)
    {
        if (address(source_) == address(0) || admin == address(0)) revert InvalidParams();
        source = source_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setParams(minInterval_, maxStaleness_, maxRatePerYear_);

        uint256 raw = source_.currentIndex();
        if (raw == 0 || raw > type(uint192).max) revert InvalidIndex();
        lastRawIndex = raw;
        _obs[0] = Observation({timestamp: uint64(block.timestamp), index: uint192(raw)});
        _count = 1;
        emit Snapshot(0, block.timestamp, raw, raw, false);
    }

    // ------------------------------------------------------------------------------------------ keeper

    /// @notice Permissionless: record a new observation if `minInterval` has elapsed since the last one.
    /// @return written True if an observation was stored.
    function snapshot() external override returns (bool written) {
        Observation memory last = _obs[_head];
        if (block.timestamp < uint256(last.timestamp) + minInterval) return false;

        uint256 raw = 0;
        try source.currentIndex() returns (uint256 r) {
            raw = r;
        } catch {
            emit SourceReadFailed(block.timestamp);
            return false;
        }
        if (raw == 0 || raw > type(uint192).max) {
            emit SourceReadFailed(block.timestamp);
            return false;
        }

        uint256 prevRaw = lastRawIndex;
        (uint256 newIndex, bool clamped) = _chain(last, prevRaw, raw, block.timestamp);
        if (_isMaterialDrop(prevRaw, raw) && !impaired) {
            impaired = true;
            emit SourceImpaired(raw, prevRaw, block.timestamp);
        }
        if (newIndex == 0) newIndex = 1;

        // effects
        uint256 slot = (_head + 1) % CAPACITY;
        _obs[slot] = Observation({timestamp: uint64(block.timestamp), index: uint192(newIndex)});
        _head = slot;
        if (_count < CAPACITY) _count++;
        lastRawIndex = raw;
        emit Snapshot(slot, block.timestamp, newIndex, raw, clamped);
        return true;
    }

    function snapshotDue() external view override returns (bool) {
        return block.timestamp >= uint256(_obs[_head].timestamp) + minInterval;
    }

    // ------------------------------------------------------------------------------------------ views

    /// @notice Live oracle index: latest observation extended by the (clamped) growth of the source since then.
    function currentIndex() public view override returns (uint256) {
        Observation memory last = _obs[_head];
        // exact equality is intended: a snapshot in this very block already holds the live index
        // slither-disable-start incorrect-equality
        if (block.timestamp == last.timestamp) return last.index;
        // slither-disable-end incorrect-equality
        try source.currentIndex() returns (uint256 raw) {
            if (raw == 0) return last.index;
            (uint256 idx,) = _chain(last, lastRawIndex, raw, block.timestamp);
            return idx == 0 ? 1 : idx;
        } catch {
            return last.index;
        }
    }

    /// @notice Oracle index at a past timestamp, linearly interpolated between the surrounding observations.
    /// @dev Binary search over the ring buffer: O(log CAPACITY), bounded.
    function indexAt(uint256 timestamp) public view override returns (uint256) {
        Observation memory latest = _obs[_head];
        // exact-timestamp lookups (now / latest observation) are intended equality checks, not balance checks
        // slither-disable-start incorrect-equality
        if (timestamp == block.timestamp && timestamp > latest.timestamp) return currentIndex();
        // slither-disable-end incorrect-equality
        if (timestamp > latest.timestamp) revert TimestampNotObserved(timestamp, latest.timestamp);
        // slither-disable-start incorrect-equality
        if (timestamp == latest.timestamp) return latest.index;
        // slither-disable-end incorrect-equality

        uint256 oldestSlot = _oldestSlot();
        Observation memory oldest = _obs[oldestSlot];
        if (timestamp < oldest.timestamp) revert TimestampTooOld(timestamp, oldest.timestamp);
        if (timestamp == oldest.timestamp) return oldest.index;

        // find the largest logical i with obs(i).timestamp <= timestamp
        uint256 lo = 0;
        uint256 hi = _count - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_obs[(oldestSlot + mid) % CAPACITY].timestamp <= timestamp) lo = mid;
            else hi = mid - 1;
        }
        Observation memory a = _obs[(oldestSlot + lo) % CAPACITY];
        if (a.timestamp == timestamp) return a.index;
        Observation memory b = _obs[(oldestSlot + lo + 1) % CAPACITY];
        return _interpolate(a, b, timestamp);
    }

    /// @notice Annualised simple rate realised between two timestamps, 18 decimals. Negative if the source lost value.
    function realizedRate(uint256 fromTs, uint256 toTs) public view override returns (int256) {
        if (toTs <= fromTs) revert InvalidRange();
        return _annualise(indexAt(fromTs), indexAt(toTs), toTs - fromTs);
    }

    /// @notice Floating rate over the trailing `lookback` seconds (bounded by the buffer's oldest observation).
    function currentFloatingRate(uint256 lookback) external view override returns (int256) {
        uint256 oldestTs = _obs[_oldestSlot()].timestamp;
        uint256 fromTs = block.timestamp > lookback ? block.timestamp - lookback : 0;
        if (fromTs < oldestTs) fromTs = oldestTs;
        if (fromTs >= block.timestamp) return 0;
        return _annualise(indexAt(fromTs), currentIndex(), block.timestamp - fromTs);
    }

    function latestObservation() external view override returns (Observation memory) {
        return _obs[_head];
    }

    function oldestObservation() external view override returns (Observation memory) {
        return _obs[_oldestSlot()];
    }

    function observationCount() external view override returns (uint256) {
        return _count;
    }

    function observationAt(uint256 logicalIndex) external view returns (Observation memory) {
        if (logicalIndex >= _count) revert InvalidRange();
        return _obs[(_oldestSlot() + logicalIndex) % CAPACITY];
    }

    function isHealthy() external view override returns (bool) {
        if (impaired) return false;
        if (block.timestamp > uint256(_obs[_head].timestamp) + maxStaleness) return false;
        try source.currentIndex() returns (uint256 raw) {
            return !_isMaterialDrop(lastRawIndex, raw);
        } catch {
            return false;
        }
    }

    // ------------------------------------------------------------------------------------------ admin

    function setParams(uint256 minInterval_, uint256 maxStaleness_, uint256 maxRatePerYear_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setParams(minInterval_, maxStaleness_, maxRatePerYear_);
    }

    /// @notice Guardian can flag a source as impaired immediately (e.g. issuer failure announced off-chain).
    function flagImpaired() external onlyRole(Roles.GUARDIAN_ROLE) {
        impaired = true;
        emit ImpairmentFlagged(msg.sender);
    }

    /// @notice Re-enabling a source is a governance action (Timelock).
    function clearImpairment() external onlyRole(DEFAULT_ADMIN_ROLE) {
        impaired = false;
        emit ImpairmentCleared(msg.sender);
    }

    // ------------------------------------------------------------------------------------------ internal

    function _setParams(uint256 minInterval_, uint256 maxStaleness_, uint256 maxRatePerYear_) internal {
        if (minInterval_ == 0 || maxStaleness_ < minInterval_ || maxRatePerYear_ == 0 || maxRatePerYear_ > 10e18) {
            revert InvalidParams();
        }
        minInterval = minInterval_;
        maxStaleness = maxStaleness_;
        maxRatePerYear = maxRatePerYear_;
        emit ParamsUpdated(minInterval_, maxStaleness_, maxRatePerYear_);
    }

    /// @dev newIndex = last.index * clamp(raw / prevRaw). Growth above maxRatePerYear over the elapsed time is cut.
    function _chain(Observation memory last, uint256 prevRaw, uint256 raw, uint256 nowTs)
        internal
        view
        returns (uint256 newIndex, bool clamped)
    {
        uint256 growth = mulDiv(raw, Constants.WAD, prevRaw);
        uint256 dt = nowTs - last.timestamp;
        uint256 maxGrowth = Constants.WAD + mulDiv(maxRatePerYear, dt, Constants.YEAR);
        if (growth > maxGrowth) {
            growth = maxGrowth;
            clamped = true;
        }
        newIndex = mulDiv(uint256(last.index), growth, Constants.WAD);
    }

    function _interpolate(Observation memory a, Observation memory b, uint256 t) internal pure returns (uint256) {
        uint256 span = uint256(b.timestamp) - a.timestamp;
        uint256 dt = t - a.timestamp;
        if (b.index >= a.index) return uint256(a.index) + mulDiv(uint256(b.index) - a.index, dt, span);
        return uint256(a.index) - mulDiv(uint256(a.index) - b.index, dt, span);
    }

    function _annualise(uint256 i0, uint256 i1, uint256 dt) internal pure returns (int256) {
        if (i1 >= i0) return int256(mulDiv(i1 - i0, Constants.WAD * Constants.YEAR, i0 * dt));
        return -int256(mulDiv(i0 - i1, Constants.WAD * Constants.YEAR, i0 * dt));
    }

    /// @dev Drops below 1e-6 relative are treated as share-price rounding, not impairment (still passed through).
    function _isMaterialDrop(uint256 prevRaw, uint256 raw) internal pure returns (bool) {
        return raw < prevRaw && mulDiv(prevRaw - raw, Constants.WAD, prevRaw) > Constants.IMPAIRMENT_TOLERANCE;
    }

    function _oldestSlot() internal view returns (uint256) {
        return _count < CAPACITY ? 0 : (_head + 1) % CAPACITY;
    }
}

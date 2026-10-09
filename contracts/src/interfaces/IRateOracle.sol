// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRateSource} from "./IRateSource.sol";

interface IRateOracle {
    struct Observation {
        uint64 timestamp;
        uint192 index; // 18 decimals, chained product of clamped period growth factors
    }

    event Snapshot(uint256 indexed slot, uint256 timestamp, uint256 index, uint256 rawIndex, bool clamped);
    event SourceImpaired(uint256 rawIndex, uint256 previousRawIndex, uint256 timestamp);
    event SourceReadFailed(uint256 timestamp);
    event ImpairmentFlagged(address indexed by);
    event ImpairmentCleared(address indexed by);
    event ParamsUpdated(uint256 minInterval, uint256 maxStaleness, uint256 maxRatePerYear);

    function source() external view returns (IRateSource);
    function snapshot() external returns (bool written);
    function snapshotDue() external view returns (bool);
    function currentIndex() external view returns (uint256);
    function indexAt(uint256 timestamp) external view returns (uint256);
    function realizedRate(uint256 fromTs, uint256 toTs) external view returns (int256);
    function currentFloatingRate(uint256 lookback) external view returns (int256);
    function latestObservation() external view returns (Observation memory);
    function oldestObservation() external view returns (Observation memory);
    function observationCount() external view returns (uint256);
    function isHealthy() external view returns (bool);
    function impaired() external view returns (bool);
}

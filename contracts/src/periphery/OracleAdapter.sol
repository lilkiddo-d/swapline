// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title OracleAdapter
/// @notice Swappable collateral pricing (Chainlink AggregatorV3 feeds) with staleness, peg-deviation and optional L2
///         sequencer-uptime checks. The MarginEngine uses it as a circuit breaker: if the margin stablecoin is stale
///         or off-peg, new risk is blocked while closes, top-ups, settlement and liquidations continue.
/// @dev Robinhood Chain has no Chainlink L2 sequencer uptime feed at the time of writing; `sequencerFeed` is optional
///      (address(0) disables the check) so one can be plugged in later via the Timelock.
contract OracleAdapter is IOracleAdapter, AccessControl {
    struct FeedConfig {
        IAggregatorV3 feed;
        uint256 heartbeat; // max age of an answer, seconds
        uint256 peg; // expected price, 18 decimals (1e18 for a USD stablecoin; 0 = no peg check)
        uint256 maxDeviation; // allowed |price - peg|, 18 decimals
    }

    mapping(address token => FeedConfig) public feeds;
    IAggregatorV3 public sequencerFeed;
    uint256 public sequencerGracePeriod;

    event FeedSet(address indexed token, address feed, uint256 heartbeat, uint256 peg, uint256 maxDeviation);
    event SequencerFeedSet(address feed, uint256 gracePeriod);

    error UnsupportedToken(address token);
    error StalePrice(address token, uint256 updatedAt);
    error InvalidPrice(address token, int256 answer);
    error SequencerDown();
    error InvalidConfig();

    constructor(address admin) {
        if (admin == address(0)) revert InvalidConfig();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setFeed(address token, FeedConfig calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || address(cfg.feed) == address(0) || cfg.heartbeat == 0) revert InvalidConfig();
        feeds[token] = cfg;
        emit FeedSet(token, address(cfg.feed), cfg.heartbeat, cfg.peg, cfg.maxDeviation);
    }

    function setSequencerFeed(IAggregatorV3 feed, uint256 gracePeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        sequencerFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(address(feed), gracePeriod);
    }

    function getPrice(address token) public view override returns (uint256) {
        FeedConfig memory cfg = feeds[token];
        if (address(cfg.feed) == address(0)) revert UnsupportedToken(token);
        _checkSequencer();
        // roundId/answeredInRound are deprecated in OCR feeds; staleness is enforced via updatedAt below
        // slither-disable-start unused-return
        (, int256 answer,, uint256 updatedAt,) = cfg.feed.latestRoundData();
        // slither-disable-end unused-return
        if (answer <= 0) revert InvalidPrice(token, answer);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > cfg.heartbeat) {
            revert StalePrice(token, updatedAt);
        }
        return mulDiv(uint256(answer), 1e18, 10 ** uint256(cfg.feed.decimals()));
    }

    function isCollateralHealthy(address token) external view override returns (bool) {
        FeedConfig memory cfg = feeds[token];
        try this.getPrice(token) returns (uint256 p) {
            if (cfg.peg == 0) return true;
            uint256 diff = p > cfg.peg ? p - cfg.peg : cfg.peg - p;
            return diff <= cfg.maxDeviation;
        } catch {
            return false;
        }
    }

    function _checkSequencer() internal view {
        IAggregatorV3 f = sequencerFeed;
        if (address(f) == address(0)) return;
        // slither-disable-start unused-return
        (, int256 answer, uint256 startedAt,,) = f.latestRoundData();
        // slither-disable-end unused-return
        // answer 0 = up, 1 = down
        if (answer != 0 || block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerDown();
    }
}

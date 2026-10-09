// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IRateSource} from "../../interfaces/IRateSource.sol";
import {IAggregatorV3} from "../../interfaces/IAggregatorV3.sol";

/// @title ChainlinkRateSource
/// @notice Index = an on-chain exchange-rate feed (Chainlink AggregatorV3 interface), for yield tokens that live on
///         Robinhood Chain as bridged representations without an ERC-4626 share price (e.g. Maple syrupUSDG, whose
///         "syrupUSDG / USDG Exchange Rate" feed is published by Maple).
/// @dev Reverts when the feed is stale or non-positive; RateOracle treats a reverting source as a failed read and the
///      oracle becomes unhealthy once `maxStaleness` passes, halting new risk.
contract ChainlinkRateSource is IRateSource {
    IAggregatorV3 public immutable feed;
    IERC20 public immutable yieldToken;
    address public immutable override underlying;
    uint256 public immutable maxAge;
    uint256 private immutable _scale;
    string private _description;

    error ZeroAddress();
    error StaleFeed(uint256 updatedAt);
    error InvalidAnswer(int256 answer);

    constructor(
        IAggregatorV3 feed_,
        IERC20 yieldToken_,
        address underlying_,
        uint256 maxAge_,
        string memory description_
    ) {
        if (address(feed_) == address(0) || address(yieldToken_) == address(0) || underlying_ == address(0)) {
            revert ZeroAddress();
        }
        feed = feed_;
        yieldToken = yieldToken_;
        underlying = underlying_;
        maxAge = maxAge_;
        _scale = 10 ** uint256(feed_.decimals());
        _description = description_;
    }

    function currentIndex() public view override returns (uint256) {
        // roundId/answeredInRound are deprecated in OCR feeds; staleness is enforced via updatedAt below
        // slither-disable-start unused-return
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        // slither-disable-end unused-return
        if (answer <= 0) revert InvalidAnswer(answer);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) revert StaleFeed(updatedAt);
        return mulDiv(uint256(answer), 1e18, _scale);
    }

    /// @dev Value of the yield token supply on this chain, in underlying units (both 6 decimals for syrupUSDG/USDG).
    function totalValue() external view override returns (uint256) {
        return mulDiv(yieldToken.totalSupply(), currentIndex(), 1e18);
    }

    function description() external view override returns (string memory) {
        return _description;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SwapMarket} from "./SwapMarket.sol";
import {RateVAMM} from "./RateVAMM.sol";
import {LPPositions} from "./LPPositions.sol";
import {MarginEngine} from "./MarginEngine.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {IRateOracle} from "../interfaces/IRateOracle.sol";

/// @title MarketFactory
/// @notice Creates (rate source, maturity) markets as minimal clones of SwapMarket + RateVAMM. Market creation is a
///         Timelock action (new sources and maturities are what $SWPL stakers vote on, advisory).
contract MarketFactory is AccessControl {
    struct CreateParams {
        IRateOracle oracle;
        uint256 maturity;
        int24 tickSpacing;
        uint256 initialRate;
        SwapMarket.MarketParams marketParams;
        IMarginEngine.RiskParams riskParams;
    }

    address public immutable marketImplementation;
    address public immutable vammImplementation;
    MarginEngine public immutable marginEngine;
    LPPositions public immutable lpPositions;

    address[] private _markets;
    mapping(address oracle => mapping(uint256 maturity => address)) public marketFor;

    event MarketCreated(
        address indexed market, address indexed vamm, address indexed oracle, uint256 maturity, uint256 initialRate
    );

    error MarketExists();

    constructor(address admin, MarginEngine marginEngine_, LPPositions lpPositions_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        marginEngine = marginEngine_;
        lpPositions = lpPositions_;
        marketImplementation = address(new SwapMarket());
        vammImplementation = address(new RateVAMM());
    }

    function createMarket(CreateParams calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address market) {
        if (marketFor[address(p.oracle)][p.maturity] != address(0)) revert MarketExists();
        market = Clones.clone(marketImplementation);
        address vamm = Clones.clone(vammImplementation);
        marketFor[address(p.oracle)][p.maturity] = market;
        _markets.push(market);

        RateVAMM(vamm).initialize(market, p.tickSpacing, p.initialRate);
        SwapMarket(market).initialize(
            IMarginEngine(address(marginEngine)), RateVAMM(vamm), lpPositions, p.oracle, p.maturity, p.marketParams
        );
        lpPositions.registerMarket(market);
        marginEngine.registerMarket(market, p.riskParams);
        emit MarketCreated(market, vamm, address(p.oracle), p.maturity, p.initialRate);
    }

    function markets() external view returns (address[] memory) {
        return _markets;
    }

    function marketCount() external view returns (uint256) {
        return _markets.length;
    }
}

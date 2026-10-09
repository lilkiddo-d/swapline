// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SwaplineTimelock} from "../src/governance/SwaplineTimelock.sol";
import {ComplianceRegistry} from "../src/compliance/ComplianceRegistry.sol";
import {OracleAdapter} from "../src/periphery/OracleAdapter.sol";
import {MarginEngine} from "../src/core/MarginEngine.sol";
import {LPPositions} from "../src/core/LPPositions.sol";
import {MarketFactory} from "../src/core/MarketFactory.sol";
import {SwapMarket} from "../src/core/SwapMarket.sol";
import {Liquidator} from "../src/core/Liquidator.sol";
import {FeeCollector, IInsuranceSink, IStakingRewards} from "../src/fees/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/token/ProjectTokenHooks.sol";
import {RateOracle} from "../src/oracle/RateOracle.sol";
import {ERC4626RateSource} from "../src/oracle/sources/ERC4626RateSource.sol";
import {SparkVaultRateSource, ISparkVault} from "../src/oracle/sources/SparkVaultRateSource.sol";
import {ChainlinkRateSource} from "../src/oracle/sources/ChainlinkRateSource.sol";
import {FixedRateVault} from "../src/vault/FixedRateVault.sol";
import {IRateSource} from "../src/interfaces/IRateSource.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IMarginEngine} from "../src/interfaces/IMarginEngine.sol";
import {Roles} from "../src/libraries/Roles.sol";

/// @title SwaplineDeployer
/// @notice Deployment + wiring logic shared by script/Deploy.s.sol and the test suite (unit and fork tests run the
///         exact same code path that ships to mainnet).
abstract contract SwaplineDeployer {
    enum SourceKind {
        ERC4626,
        Spark,
        Chainlink
    }

    struct SourceConfig {
        string key;
        SourceKind kind;
        address target; // ERC-4626 vault, Spark vault, or exchange-rate feed
        address yieldToken; // the yield-bearing token (== target for vaults)
        uint256 maxAge; // feed staleness (Chainlink kind only)
        uint256 maxRatePerYear;
        uint256 initialRate;
        bool fixedRateVault;
        string description;
    }

    struct Config {
        address deployer;
        address stablecoin;
        address stablecoinUsdFeed;
        uint256 stablecoinHeartbeat;
        address guardian;
        address proposer;
        address treasury;
        uint256 timelockDelay;
        uint256[] maturityDays;
        SourceConfig[] sources;
    }

    struct MarketDeployment {
        string sourceKey;
        uint256 maturityDays;
        uint256 maturity;
        address market;
        address vamm;
        address vault;
    }

    struct Deployment {
        SwaplineTimelock timelock;
        ComplianceRegistry compliance;
        OracleAdapter oracleAdapter;
        MarginEngine marginEngine;
        LPPositions lpPositions;
        MarketFactory factory;
        Liquidator liquidator;
        FeeCollector feeCollector;
        ProjectTokenHooks projectTokenHooks;
        address[] rateSources;
        address[] oracles;
        MarketDeployment[] markets;
    }

    // Default risk/market parameters (see DECISIONS.md for rationale).
    uint256 internal constant ORACLE_MIN_INTERVAL = 1 hours;
    uint256 internal constant ORACLE_MAX_STALENESS = 2 days;
    int24 internal constant TICK_SPACING = 10; // 10bp LP ranges

    function _marketParams() internal pure virtual returns (SwapMarket.MarketParams memory) {
        return SwapMarket.MarketParams({
            feeRate: 0.003e18, // 30bp per year of notional x time
            protocolFeeBps: 2_000, // 20% protocol, 80% LPs
            maxOpenInterestBps: 4_000, // gross OI (both sides) <= 40% of source TVL
            tradeCutoff: 1 hours
        });
    }

    function _riskParams() internal pure virtual returns (IMarginEngine.RiskParams memory) {
        return IMarginEngine.RiskParams({
            imShock: 0.03e18, // 300bp annualised rate move
            mmShock: 0.015e18, // 150bp
            minMargin: 5e6, // 5 stablecoin units (6 decimals)
            minTau: 1 days,
            liquidationRewardBps: 1_000, // 10% of maintenance requirement
            markInterval: 1 days // daily mark-to-market
        });
    }

    function _deploySwapline(Config memory c) internal returns (Deployment memory d) {
        address me = c.deployer;
        IERC20 usd = IERC20(c.stablecoin);

        {
            address[] memory proposers = new address[](1);
            proposers[0] = c.proposer;
            address[] memory executors = new address[](1);
            executors[0] = address(0); // anyone may execute a ready operation
            d.timelock = new SwaplineTimelock(c.timelockDelay, proposers, executors);
        }

        d.compliance = new ComplianceRegistry(me);
        d.oracleAdapter = new OracleAdapter(me);
        if (c.stablecoinUsdFeed != address(0)) {
            d.oracleAdapter.setFeed(
                c.stablecoin,
                OracleAdapter.FeedConfig({
                    feed: IAggregatorV3(c.stablecoinUsdFeed),
                    heartbeat: c.stablecoinHeartbeat,
                    peg: 1e18,
                    maxDeviation: 0.02e18
                })
            );
        }

        d.marginEngine = new MarginEngine(usd, me, c.guardian);
        d.lpPositions = new LPPositions(me);
        d.factory = new MarketFactory(me, d.marginEngine, d.lpPositions);
        d.marginEngine.grantRole(Roles.FACTORY_ROLE, address(d.factory));
        d.lpPositions.grantRole(Roles.FACTORY_ROLE, address(d.factory));

        d.projectTokenHooks = new ProjectTokenHooks(usd, me);
        d.feeCollector = new FeeCollector(usd, me, c.treasury, IInsuranceSink(address(d.marginEngine)), 2_000, 5_000);
        d.feeCollector.setConfig(
            c.treasury,
            IInsuranceSink(address(d.marginEngine)),
            IStakingRewards(address(d.projectTokenHooks)),
            2_000, // 20% of protocol fees to the insurance fund
            5_000 // 50% to $SWPL stakers once the token is set (otherwise treasury)
        );

        d.marginEngine.setOracleAdapter(d.oracleAdapter);
        d.marginEngine.setCompliance(d.compliance);
        d.marginEngine.setFeeCollector(address(d.feeCollector));

        d.liquidator = new Liquidator(me, 0.03e18);
        d.marginEngine.grantRole(Roles.LIQUIDATOR_ROLE, address(d.liquidator));

        uint256 n = c.sources.length;
        d.rateSources = new address[](n);
        d.oracles = new address[](n);
        d.markets = new MarketDeployment[](n * c.maturityDays.length);
        for (uint256 i; i < n; ++i) {
            (d.rateSources[i], d.oracles[i]) = _deploySource(c, c.sources[i]);
            for (uint256 j; j < c.maturityDays.length; ++j) {
                d.markets[i * c.maturityDays.length + j] =
                    _deployMarket(d, c, c.sources[i], RateOracle(d.oracles[i]), c.maturityDays[j]);
            }
        }

        _handOff(d, me);
    }

    function _deploySource(Config memory c, SourceConfig memory s) internal returns (address src, address oracle) {
        if (s.kind == SourceKind.ERC4626) {
            src = address(new ERC4626RateSource(IERC4626(s.target), s.description));
        } else if (s.kind == SourceKind.Spark) {
            src = address(new SparkVaultRateSource(ISparkVault(s.target), s.description));
        } else {
            src = address(
                new ChainlinkRateSource(
                    IAggregatorV3(s.target), IERC20(s.yieldToken), c.stablecoin, s.maxAge, s.description
                )
            );
        }
        RateOracle o =
            new RateOracle(IRateSource(src), c.deployer, ORACLE_MIN_INTERVAL, ORACLE_MAX_STALENESS, s.maxRatePerYear);
        if (c.guardian != address(0)) o.grantRole(Roles.GUARDIAN_ROLE, c.guardian);
        oracle = address(o);
    }

    function _deployMarket(
        Deployment memory d,
        Config memory c,
        SourceConfig memory s,
        RateOracle oracle,
        uint256 maturityDays
    ) internal returns (MarketDeployment memory m) {
        m.sourceKey = s.key;
        m.maturityDays = maturityDays;
        m.maturity = ((block.timestamp + maturityDays * 1 days) / 1 days) * 1 days; // 00:00 UTC
        m.market = d.factory.createMarket(
            MarketFactory.CreateParams({
                oracle: oracle,
                maturity: m.maturity,
                tickSpacing: TICK_SPACING,
                initialRate: s.initialRate,
                marketParams: _marketParams(),
                riskParams: _riskParams()
            })
        );
        m.vamm = SwapMarket(m.market).vamm();
        if (s.fixedRateVault) {
            m.vault = address(
                new FixedRateVault(
                    IERC20(c.stablecoin),
                    string.concat("Swapline Fixed ", s.key, " ", _uintToString(maturityDays), "D"),
                    string.concat("sw", s.key, "-", _uintToString(maturityDays), "D"),
                    SwapMarket(m.market),
                    IERC4626(s.target),
                    500, // 5% of each deposit posted as swap margin
                    0.005e18, // accept at most 50bp below the spot fixed rate
                    1 days // deposits close 1 day before maturity
                )
            );
        }
    }

    /// @dev Give DEFAULT_ADMIN_ROLE to the Timelock everywhere and renounce every role held by the deployer.
    function _handOff(Deployment memory d, address me) internal {
        address tl = address(d.timelock);
        IAccessControl[8] memory acs = [
            IAccessControl(address(d.compliance)),
            IAccessControl(address(d.oracleAdapter)),
            IAccessControl(address(d.marginEngine)),
            IAccessControl(address(d.lpPositions)),
            IAccessControl(address(d.factory)),
            IAccessControl(address(d.liquidator)),
            IAccessControl(address(d.feeCollector)),
            IAccessControl(address(d.projectTokenHooks))
        ];
        d.compliance.grantRole(Roles.COMPLIANCE_ROLE, tl);
        for (uint256 i; i < 8; ++i) {
            acs[i].grantRole(0x00, tl);
            acs[i].renounceRole(0x00, me);
        }
        for (uint256 i; i < d.oracles.length; ++i) {
            IAccessControl(d.oracles[i]).grantRole(0x00, tl);
            IAccessControl(d.oracles[i]).renounceRole(0x00, me);
        }
    }

    function _uintToString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) len++;
        bytes memory b = new bytes(len);
        for (uint256 t = v; t != 0; t /= 10) b[--len] = bytes1(uint8(48 + (t % 10)));
        return string(b);
    }
}

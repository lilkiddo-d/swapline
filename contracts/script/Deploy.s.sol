// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SwaplineDeployer} from "./SwaplineDeployer.sol";
import {RateOracle} from "../src/oracle/RateOracle.sol";

/// @title Deploy
/// @notice One script that deploys and wires all of Swapline, hands admin to the 48h Timelock, and writes
///         deployments/<chainId>.json plus the frontend config app/src/config/deployments.<chainId>.json.
///
///   Mainnet (signs ONLY via the Foundry keystore account `swapline-deployer`; no private key ever touches disk):
///     forge script script/Deploy.s.sol --rpc-url robinhood --account swapline-deployer --broadcast \
///       --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
///
///   Dry run (simulation only, nothing is signed or sent):
///     forge script script/Deploy.s.sol --rpc-url robinhood --sender <deployer address>
///
/// Optional env: GUARDIAN, TIMELOCK_PROPOSER, TREASURY (default: the deployer — use a multisig in production),
///               TIMELOCK_DELAY (seconds, >= 172800).
contract Deploy is Script, SwaplineDeployer {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant LOCAL_FORK_CHAIN_ID = 31337;

    error UnsupportedChain(uint256 chainId);
    error MissingAddress(string what);

    function run() external returns (Deployment memory dep) {
        if (block.chainid != ROBINHOOD_CHAIN_ID && block.chainid != LOCAL_FORK_CHAIN_ID) {
            revert UnsupportedChain(block.chainid);
        }
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/../config/robinhood.json"));
        Config memory c = _loadConfig(json);

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        c.deployer = sender;
        c.guardian = vm.envOr("GUARDIAN", sender);
        c.proposer = vm.envOr("TIMELOCK_PROPOSER", sender);
        c.treasury = vm.envOr("TREASURY", sender);
        c.timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(48 hours));
        _preflight(c);

        dep = _deploySwapline(c);
        vm.stopBroadcast();

        _postflight(dep, c);
        _write(dep, c);
    }

    // ------------------------------------------------------------------------------------------ config

    function _loadConfig(string memory json) internal view returns (Config memory c) {
        c.stablecoin = vm.parseJsonAddress(json, ".tokens.USDG.address");
        c.stablecoinUsdFeed = vm.parseJsonAddress(json, ".oracles.USDG_USD.address");
        c.stablecoinHeartbeat = vm.parseJsonUint(json, ".oracles.USDG_USD.heartbeatSeconds");
        c.maturityDays = vm.parseJsonUintArray(json, ".maturitiesDays");

        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".rateSources[", vm.toString(n), "]"))) n++;
        c.sources = new SourceConfig[](n);
        for (uint256 i; i < n; ++i) {
            string memory p = string.concat(".rateSources[", vm.toString(i), "]");
            string memory kind = vm.parseJsonString(json, string.concat(p, ".kind"));
            c.sources[i] = SourceConfig({
                key: vm.parseJsonString(json, string.concat(p, ".key")),
                kind: _kind(kind),
                target: vm.parseJsonAddress(json, string.concat(p, ".target")),
                yieldToken: vm.parseJsonAddress(json, string.concat(p, ".yieldToken")),
                maxAge: vm.parseJsonUint(json, string.concat(p, ".maxAgeSeconds")),
                maxRatePerYear: vm.parseJsonUint(json, string.concat(p, ".maxRatePerYear")),
                initialRate: vm.parseJsonUint(json, string.concat(p, ".initialRate")),
                fixedRateVault: vm.parseJsonBool(json, string.concat(p, ".fixedRateVault")),
                description: vm.parseJsonString(json, string.concat(p, ".description"))
            });
        }
    }

    function _kind(string memory k) internal pure returns (SourceKind) {
        bytes32 h = keccak256(bytes(k));
        if (h == keccak256("erc4626")) return SourceKind.ERC4626;
        if (h == keccak256("spark")) return SourceKind.Spark;
        if (h == keccak256("chainlink")) return SourceKind.Chainlink;
        revert MissingAddress(k);
    }

    /// @dev Refuse to deploy against addresses that have no code on this chain.
    function _preflight(Config memory c) internal view {
        if (c.stablecoin.code.length == 0) revert MissingAddress("USDG");
        if (c.stablecoinUsdFeed.code.length == 0) revert MissingAddress("USDG/USD feed");
        for (uint256 i; i < c.sources.length; ++i) {
            if (c.sources[i].target.code.length == 0) revert MissingAddress(c.sources[i].key);
            if (c.sources[i].yieldToken.code.length == 0) revert MissingAddress(c.sources[i].key);
        }
        if (c.guardian == c.deployer) console2.log("WARNING: GUARDIAN defaults to the deployer; set a multisig.");
        if (c.proposer == c.deployer) console2.log("WARNING: TIMELOCK_PROPOSER defaults to the deployer.");
    }

    /// @dev Assert the hand-off actually happened: the deployer must hold no admin role anywhere.
    function _postflight(Deployment memory dep, Config memory c) internal view {
        require(!dep.marginEngine.hasRole(0x00, c.deployer), "deployer still admin: MarginEngine");
        require(dep.marginEngine.hasRole(0x00, address(dep.timelock)), "timelock not admin: MarginEngine");
        require(!dep.factory.hasRole(0x00, c.deployer), "deployer still admin: MarketFactory");
        require(!dep.projectTokenHooks.hasRole(0x00, c.deployer), "deployer still admin: hooks");
        require(address(dep.projectTokenHooks.projectToken()) == address(0), "project token must be unset");
        for (uint256 i; i < dep.oracles.length; ++i) {
            require(!RateOracle(dep.oracles[i]).hasRole(0x00, c.deployer), "deployer still admin: oracle");
        }
        require(dep.timelock.getMinDelay() >= 48 hours, "timelock delay");
    }

    // ------------------------------------------------------------------------------------------ output

    function _write(Deployment memory dep, Config memory c) internal {
        string memory root = string.concat(vm.projectRoot(), "/..");
        bool dry = vm.isContext(VmSafe.ForgeContext.ScriptDryRun);
        string memory suffix = dry ? ".dry-run.json" : ".json";
        string memory chain = vm.toString(block.chainid);
        string memory out = _json(dep, c);
        vm.writeJson(out, string.concat(root, "/deployments/", chain, suffix));
        if (!dry) vm.writeJson(out, string.concat(root, "/app/src/config/deployments.", chain, ".json"));
        console2.log("Deployment written:", string.concat("deployments/", chain, suffix));
    }

    /// @dev On Arbitrum-based chains block.number is an L1 estimate; event logs are indexed by the L2 number.
    function _l2BlockNumber() internal view returns (uint256) {
        if (block.chainid != ROBINHOOD_CHAIN_ID) return block.number;
        (bool ok, bytes memory ret) = address(0x64).staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        return ok && ret.length == 32 ? abi.decode(ret, (uint256)) : block.number;
    }

    function _json(Deployment memory dep, Config memory c) internal returns (string memory) {
        string memory k = "core";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "deployedAt", block.timestamp);
        vm.serializeUint(k, "deployBlock", _l2BlockNumber());
        vm.serializeAddress(k, "deployer", c.deployer);
        vm.serializeAddress(k, "guardian", c.guardian);
        vm.serializeAddress(k, "stablecoin", c.stablecoin);
        vm.serializeAddress(k, "timelock", address(dep.timelock));
        vm.serializeAddress(k, "complianceRegistry", address(dep.compliance));
        vm.serializeAddress(k, "oracleAdapter", address(dep.oracleAdapter));
        vm.serializeAddress(k, "marginEngine", address(dep.marginEngine));
        vm.serializeAddress(k, "lpPositions", address(dep.lpPositions));
        vm.serializeAddress(k, "marketFactory", address(dep.factory));
        vm.serializeAddress(k, "liquidator", address(dep.liquidator));
        vm.serializeAddress(k, "feeCollector", address(dep.feeCollector));
        vm.serializeAddress(k, "projectTokenHooks", address(dep.projectTokenHooks));

        string[] memory sources = new string[](dep.oracles.length);
        for (uint256 i; i < dep.oracles.length; ++i) {
            string memory sk = string.concat("source", vm.toString(i));
            vm.serializeString(sk, "key", c.sources[i].key);
            vm.serializeString(sk, "description", c.sources[i].description);
            vm.serializeAddress(sk, "yieldToken", c.sources[i].yieldToken);
            vm.serializeAddress(sk, "rateSource", dep.rateSources[i]);
            sources[i] = vm.serializeAddress(sk, "oracle", dep.oracles[i]);
        }
        vm.serializeString(k, "sources", sources);

        string[] memory markets = new string[](dep.markets.length);
        for (uint256 i; i < dep.markets.length; ++i) {
            MarketDeployment memory m = dep.markets[i];
            string memory mk = string.concat("market", vm.toString(i));
            vm.serializeString(mk, "source", m.sourceKey);
            vm.serializeUint(mk, "maturityDays", m.maturityDays);
            vm.serializeUint(mk, "maturity", m.maturity);
            vm.serializeAddress(mk, "vamm", m.vamm);
            vm.serializeAddress(mk, "vault", m.vault);
            markets[i] = vm.serializeAddress(mk, "market", m.market);
        }
        return vm.serializeString(k, "markets", markets);
    }
}

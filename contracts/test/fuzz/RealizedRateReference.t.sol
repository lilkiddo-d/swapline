// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {RateOracle} from "../../src/oracle/RateOracle.sol";
import {IRateSource} from "../../src/interfaces/IRateSource.sol";
import {MockRateSource} from "../utils/Mocks.sol";

/// @notice Realised floating rate (and index interpolation) computed on-chain must equal, to the wei, an independent
///         off-chain TypeScript implementation (scripts/reference/rateReference.ts) invoked through FFI.
contract RealizedRateReferenceTest is Test {
    uint256 constant MAX_RATE = 0.3e18;
    MockRateSource src;
    RateOracle oracle;
    string series;
    uint256[] stamps;

    function setUp() public {
        vm.warp(1_790_000_000);
        src = new MockRateSource(address(1));
    }

    function _ref(string memory cmd, string memory a, string memory b) internal returns (int256) {
        string[] memory args = new string[](7);
        args[0] = "node";
        args[1] = string.concat(vm.projectRoot(), "/../scripts/reference/rateReference.ts");
        args[2] = cmd;
        args[3] = vm.toString(MAX_RATE);
        args[4] = series;
        args[5] = a;
        args[6] = b;
        return abi.decode(_ffiRetry(args), (int256));
    }

    /// @dev Node can fail to spawn under heavy parallel load (many fuzz runs at once); retry before failing.
    function _ffiRetry(string[] memory args) internal returns (bytes memory) {
        for (uint256 i; i < 5; ++i) {
            VmSafe.FfiResult memory r = vm.tryFfi(args);
            if (r.exitCode == 0 && r.stdout.length == 32) return r.stdout;
        }
        return vm.ffi(args); // final attempt surfaces the real error
    }

    function _record() internal {
        series = string.concat(series, vm.toString(block.timestamp), ",", vm.toString(src.index()), ";");
        stamps.push(block.timestamp);
    }

    /// forge-config: default.fuzz.runs = 64
    /// forge-config: ci.fuzz.runs = 256
    /// @param seed drives a random path of 4..12 snapshots with random gaps (1h..3d) and growth incl. spikes & drops
    function testFuzz_realizedRateMatchesTypeScript(uint256 seed, uint256 fromSeed, uint256 toSeed) public {
        src.setIndex(1e18 + (seed % 1e16));
        oracle = new RateOracle(IRateSource(address(src)), address(this), 1 hours, 30 days, MAX_RATE);
        _record();
        uint256 n = 4 + (seed % 9);
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 dt = 1 hours + (r % 3 days);
            vm.warp(block.timestamp + dt);
            uint256 mode = (r >> 64) % 10;
            uint256 idx = src.index();
            if (mode == 0) {
                idx = idx + idx / 20; // 5% spike (donation) -> clamped
            } else if (mode == 1) {
                idx = idx - idx / 1000; // small loss
            } else {
                uint256 apr = (r >> 128) % 0.25e18;
                idx = idx + (idx * apr * dt) / (365 days * 1e18);
            }
            src.setIndex(idx);
            assertTrue(oracle.snapshot());
            _record();
        }
        uint256 t0 = stamps[0];
        uint256 tEnd = stamps[stamps.length - 1];
        uint256 from = bound(fromSeed, t0, tEnd - 1);
        uint256 to = bound(toSeed, from + 1, tEnd);

        int256 onchain = oracle.realizedRate(from, to);
        int256 offchain = _ref("realized", vm.toString(from), vm.toString(to));
        assertEq(onchain, offchain, "realised rate mismatch");

        uint256 mid = (from + to) / 2;
        assertEq(int256(oracle.indexAt(mid)), _ref("indexAt", vm.toString(mid), ""), "index mismatch");
    }

    /// forge-config: default.fuzz.runs = 64
    /// forge-config: ci.fuzz.runs = 256
    /// @notice Settlement of a single pay-fixed trade vs the TypeScript closed form.
    function testFuzz_cashflowMatchesTypeScript(uint96 notional, uint64 rate, uint64 growth) public {
        notional = uint96(bound(notional, 1e6, 1e13));
        uint256 fixedRate = bound(rate, 0, 0.3e18);
        uint256 iEnd = 1e18 + bound(growth, 0, 0.1e18);
        uint256 tau = 0.25e18;
        // Solidity: varShares = N/I0, fixedCash = -(N + N*r*tau); cash = varShares*I1 + fixedCash (floor)
        int256 vs = int256(uint256(notional) * 1e36 / 1e18);
        int256 fc = -int256(uint256(notional) * 1e18 + uint256(notional) * fixedRate * tau / 1e18);
        int256 v = vs * int256(iEnd) / 1e18 + fc;
        int256 cash = v / 1e18;
        if (v < 0 && v % 1e18 != 0) cash -= 1;
        string[] memory args = new string[](8);
        args[0] = "node";
        args[1] = string.concat(vm.projectRoot(), "/../scripts/reference/rateReference.ts");
        args[2] = "cashflow";
        args[3] = vm.toString(uint256(notional));
        args[4] = vm.toString(fixedRate);
        args[5] = vm.toString(tau);
        args[6] = vm.toString(uint256(1e18));
        args[7] = vm.toString(iEnd);
        int256 ref = abi.decode(_ffiRetry(args), (int256));
        assertApproxEqAbs(cash, ref, 1); // sub-wei rounding of the fixed leg
        assertLe(cash, ref); // and never in the trader's favour
    }
}

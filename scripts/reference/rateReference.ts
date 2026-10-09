/**
 * Off-chain reference implementation of Swapline's RateOracle math (TypeScript, exact BigInt arithmetic).
 *
 * It re-derives, independently of the Solidity code:
 *   1. the oracle index chain: index_k = index_{k-1} * min(raw_k / raw_{k-1}, 1 + maxRate * dt / YEAR)
 *   2. linear interpolation of the index at arbitrary timestamps
 *   3. the realised (annualised, simple) floating rate between two timestamps
 * and also the swap settlement cashflow for a single trade.
 *
 * Used by contracts/test/fuzz/RealizedRateReference.t.sol through Foundry FFI:
 *   node scripts/reference/rateReference.ts realized <maxRatePerYear> <t0,raw0;t1,raw1;...> <from> <to>
 *   node scripts/reference/rateReference.ts cashflow <notional> <fixedRate> <tau> <indexStart> <indexEnd>
 * Output: a 0x-prefixed 32-byte two's-complement int256 (ABI encoding), which forge decodes.
 */

export const WAD = 10n ** 18n;
export const YEAR = 365n * 24n * 3600n;

export interface Observation {
  timestamp: bigint;
  index: bigint;
}

/** floor(a * b / c) for non-negative operands (Solidity mulDiv). */
export function mulDiv(a: bigint, b: bigint, c: bigint): bigint {
  if (a < 0n || b < 0n || c <= 0n) throw new Error("mulDiv expects non-negative inputs");
  return (a * b) / c;
}

/** Builds the oracle's observation chain from raw source readings (first reading seeds the chain). */
export function chainObservations(raw: Array<{ timestamp: bigint; raw: bigint }>, maxRatePerYear: bigint): Observation[] {
  if (raw.length === 0) throw new Error("no observations");
  const obs: Observation[] = [{ timestamp: raw[0].timestamp, index: raw[0].raw }];
  let prevRaw = raw[0].raw;
  for (let i = 1; i < raw.length; i++) {
    const last = obs[obs.length - 1];
    const r = raw[i].raw;
    let growth = mulDiv(r, WAD, prevRaw);
    const dt = raw[i].timestamp - last.timestamp;
    const maxGrowth = WAD + mulDiv(maxRatePerYear, dt, YEAR);
    if (growth > maxGrowth) growth = maxGrowth;
    let idx = mulDiv(last.index, growth, WAD);
    if (idx === 0n) idx = 1n;
    obs.push({ timestamp: raw[i].timestamp, index: idx });
    prevRaw = r;
  }
  return obs;
}

/** Index at timestamp t by linear interpolation (Solidity: RateOracle._interpolate). */
export function indexAt(obs: Observation[], t: bigint): bigint {
  if (t < obs[0].timestamp || t > obs[obs.length - 1].timestamp) throw new Error("timestamp out of range");
  for (let i = obs.length - 1; i >= 0; i--) {
    const a = obs[i];
    if (a.timestamp === t) return a.index;
    if (a.timestamp < t) {
      const b = obs[i + 1];
      const span = b.timestamp - a.timestamp;
      const dt = t - a.timestamp;
      if (b.index >= a.index) return a.index + mulDiv(b.index - a.index, dt, span);
      return a.index - mulDiv(a.index - b.index, dt, span);
    }
  }
  throw new Error("unreachable");
}

/** Annualised simple rate between two indices over dt seconds, 18 decimals, signed. */
export function annualise(i0: bigint, i1: bigint, dt: bigint): bigint {
  if (i1 >= i0) return mulDiv(i1 - i0, WAD * YEAR, i0 * dt);
  return -mulDiv(i0 - i1, WAD * YEAR, i0 * dt);
}

export function realizedRate(obs: Observation[], from: bigint, to: bigint): bigint {
  if (to <= from) throw new Error("invalid range");
  return annualise(indexAt(obs, from), indexAt(obs, to), to - from);
}

/**
 * Settlement cashflow for one pay-fixed trade of `notional` at `fixedRate` with `tau` years to maturity:
 *   notional * (I_end / I_start - 1) - notional * fixedRate * tau
 * (receive-fixed is the negative). Exact rational value rounded toward -infinity, in token units.
 */
export function payFixedCashflow(notional: bigint, fixedRate: bigint, tau: bigint, iStart: bigint, iEnd: bigint): bigint {
  // work in units of 1 / (WAD * WAD * iStart) to keep everything integral
  const num = notional * (iEnd - iStart) * WAD * WAD - notional * fixedRate * tau * iStart;
  const den = iStart * WAD * WAD;
  const q = num / den;
  return num < 0n && q * den !== num ? q - 1n : q;
}

export function toInt256Hex(v: bigint): string {
  const two256 = 1n << 256n;
  const u = v < 0n ? two256 + v : v;
  return "0x" + u.toString(16).padStart(64, "0");
}

function parseSeries(s: string): Array<{ timestamp: bigint; raw: bigint }> {
  return s.split(";").filter(Boolean).map((p) => {
    const [t, r] = p.split(",");
    return { timestamp: BigInt(t), raw: BigInt(r) };
  });
}

function main(argv: string[]): void {
  const [cmd, ...a] = argv;
  if (cmd === "realized") {
    const [maxRate, series, from, to] = a;
    const obs = chainObservations(parseSeries(series), BigInt(maxRate));
    process.stdout.write(toInt256Hex(realizedRate(obs, BigInt(from), BigInt(to))));
  } else if (cmd === "indexAt") {
    const [maxRate, series, t] = a;
    const obs = chainObservations(parseSeries(series), BigInt(maxRate));
    process.stdout.write(toInt256Hex(indexAt(obs, BigInt(t))));
  } else if (cmd === "cashflow") {
    const [notional, rate, tau, i0, i1] = a.map(BigInt);
    process.stdout.write(toInt256Hex(payFixedCashflow(notional, rate, tau, i0, i1)));
  } else {
    process.stderr.write("usage: rateReference.ts realized|indexAt|cashflow ...\n");
    process.exit(1);
  }
}

// run when executed directly (not when imported by the keeper / frontend)
if (process.argv[1] && /rateReference\.ts$/.test(process.argv[1])) {
  main(process.argv.slice(2));
}

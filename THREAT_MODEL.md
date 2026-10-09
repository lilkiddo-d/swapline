# Threat model

## Assets and trust
- **Funds at risk:**
  - USDG margin custodied by `MarginEngine` (per market and account), plus the LP fee pool and the insurance fund;
  - source shares held by `FixedRateVault`s;
  - USDG rewards held by `ProjectTokenHooks`.
- **Trusted:**
  - the 48h Timelock and its proposer (all admin powers);
  - the guardian (pause only);
  - the three rate-source issuers (Morpho/Steakhouse, Spark/Sky, Maple);
  - Chainlink (USDG/USD) and Maple's exchange-rate feed;
  - the Robinhood Chain sequencer.
- **Untrusted:** traders, LPs, liquidators, keepers, and anyone calling the permissionless functions (`snapshot`,
  `poke`, `settle`, `distribute`, `liquidate`).

## Top risk 1: rate-index manipulation by donating to the source
*Attack:* take a large pay-fixed (receive-floating) position, then inflate the source's share price, e.g. by
transferring assets into an ERC-4626 vault, so the realised floating leg jumps.

Mitigations, in layers:
1. **Clamped chaining** (`RateOracle._chain`). Each snapshot multiplies the oracle index by `min(raw_t/raw_{t-1}, 1 + 30%·dt/yr)`.
   Growth above the cap is discarded permanently, because the next period chains from the *raw* index. A
   10% spike in one day adds at most about 0.08% (`test_donationIsClampedAndDiscarded`). The live index used at trade
   time is clamped the same way.
2. **Economic bound.** Gross open interest per market is capped at 40% of the source's TVL
   (`maxOpenInterestBps`). Pushing the rate up by x costs about x·TVL in donations and gains at most x·OI·τ, which is
   less than x·TVL. The attack loses money.
3. **Source-level defences.**
   - spUSDG's `totalAssets = supply·chi`, so donations don't move it.
   - Steakhouse Vault V2 enforces its own `maxRate` on share-price growth.
   - syrupUSDG's index is Maple's feed, which a donation on Robinhood Chain cannot move.
4. **TWAP marks.** Liquidations use the vAMM TWAP since the last daily mark. Margin for new risk is checked against
   the worse of mark and spot.
5. **Invariant test.** `invariant_oracleIndexWithinEnvelope` holds through random 2% donation spikes.

*Residual:* sustained growth just under the cap, i.e. donating continuously at ≤30% APR. Its cost scales with TVL
while its profit is capped by OI, so it is unprofitable.

## Top risk 2: rate-source issuer failure
*Scenario:* a lending vault takes bad debt, a credit pool defaults, the issuer pauses, or the feed stops updating.

1. **Losses reach the floating leg honestly.** A falling index produces a negative realised rate, so receive-floating
   positions pay. This is economically correct, and the oracle does not paper over it.
2. **Impairment halts new risk automatically.** Any drop above 1e-6 relative sets `impaired`. Markets on that source
   then reject new risk, LP mints and vault deposits. Closes, settlement and liquidation keep working. The guardian can
   also call `flagImpaired()` on off-chain news; only the Timelock can clear it.
3. **Source unavailable.** Reverts and stale feeds are caught. A failed read stores nothing, and after `maxStaleness`
   (2 days) the oracle is unhealthy and new risk stops. Settlement interpolates between the observations around
   maturity, so a temporary outage only delays it.
4. **Bad debt.** Accounts whose loss exceeds their margin are covered by the insurance fund (20% of protocol fees).
   Anything left over is recorded in `deficit` for governance to recapitalise.
5. **Vault exposure.** `FixedRateVault` holds source shares directly, so an issuer loss hits vault depositors
   pro-rata. The risk disclosure page states this, and vaults exist only for instant-liquidity sources.

## Top risk 3: vAMM range exhaustion
*Scenario:* liquidity runs out in one direction, so trades can't fill, liquidations can't unwind, and price can jump
through empty gaps.

1. **No silent partial fills for users.** `trade` reverts with `InsufficientLiquidity` unless fully filled, and every
   trade has a caller-set `rateLimit` and `deadline`.
2. **Liquidations accept partial fills** within `rateBand` (300bp) of the current rate. An account that can't be
   fully unwound stays liquidatable and is retried later; the reward is paid only while exposure remains, so keepers
   can't drain an emptied account (regression-tested).
3. **The price can't run away.** With no initialised tick in a direction the swap stops. Jumping an empty gap moves
   the rate only to the next liquidity, never past the limit. Each swap crosses at most 64 ticks.
4. **Settlement never needs the AMM.** At maturity every account settles from the oracle, so exhausted ranges only
   affect pre-maturity exits.
5. **LP margin assumes the whole range fills**, so LPs stay solvent at the range edge.

## Other risks
- **Re-entrancy.** Every state-changing external entry is `nonReentrant` and token transfers go last. Callees are
  protocol contracts fixed at initialisation. Reviewed Slither items are listed in SLITHER_TRIAGE.md.
- **Oracle and collateral.** USDG/USD staleness (26h), peg deviation (2%) and an optional sequencer uptime feed. A
  depeg blocks new risk only.
- **Rounding.** Every rounding step favours the protocol. The invariants check that the sum of settlement cashflows
  is ≤ 0 and that custody covers all claims, and a TypeScript reference matches on-chain math to the wei via FFI.
- **Unbounded loops.** None:
  - LP ranges per account: 8;
  - tick crossings per swap: 64;
  - bitmap words searched: at most 4;
  - oracle search: binary over 1024 slots;
  - compliance batch: 200;
  - liquidation batch: 20.
- **Governance compromise.** Every admin action waits 48h in the Timelock, which can't be shortened, giving users time
  to exit. The guardian can only pause, not move funds; unpausing needs the Timelock.
- **Timestamp use.** `block.timestamp` is used for accrual and maturities, and sequencer skew of seconds is
  immaterial at annual-rate precision. `block.number` is never used (it is an L1 estimate on Robinhood Chain).
- **Share inflation** on FixedRateVault is blocked by `_decimalsOffset = 6`.
- **Compliance.** The hook only ever gates *entry*, so a misconfigured allowlist can't trap funds.

# Decisions

One line of reasoning per decision, grouped by area.

## Chain and data
- **Robinhood Chain mainnet = chain id 4663, ETH gas.** Taken from docs.robinhood.com/chain/connecting and confirmed with `cast chain-id` on the public RPC.
- **Every external address comes from an official source and is checked on-chain** (name, asset, decimals, live data) before going into `config/robinhood.json`. "Never guess an address" was a hard requirement.
- **Rate sources: steakUSDG, spUSDG, syrupUSDG.** These are the only yield-bearing USDG instruments with an on-chain exchange rate on the chain: a Morpho lending vault, the Spark savings rate, and Maple institutional credit.
- **No tokenized T-bill source.** BUIDL, USTB, OUSG, USDY and BENJI are not deployed on Robinhood Chain (2026-10-09). `ChainlinkRateSource` accepts any NAV/exchange-rate feed, so one can be added through MarketFactory once issued.
- **syrupUSDG uses Maple's on-chain exchange-rate feed.** The token on Robinhood Chain is bridged and has no local ERC-4626 share price; the feed is the issuer's published on-chain rate.
- **spUSDG uses `nowChi()` rather than `convertToAssets`.** It is RAY-precise and donation-proof by construction.
- **steakUSDG uses `convertToAssets` with a 10^(shareDecimals+12) probe.** USDG has 6 decimals; a 1-share probe would leave only 6 significant digits of rate precision.
- **USDG/USD heartbeat is 26h.** Measured updates are exactly every 24h, and 24h exactly would block new risk for seconds before each update.
- **Initial vAMM rates come from live data** (steak 4.3% via the Morpho API, spUSDG 3.44% from `vsr`, syrup 4.85% from feed history). Starting near fair value avoids an arbitrage give-away to the first traders.
- **No sequencer uptime check by default.** Chainlink publishes no sequencer uptime feed for Robinhood Chain; OracleAdapter keeps the check pluggable.
- **Contracts are verified via Etherscan v2 (chain 4663), with Blockscout as fallback.** Blockscout's API returned Cloudflare 403s to non-browser clients during testing.
- **The compiler target is `evm_version = cancun`.** MCOPY, TSTORE/TLOAD and PUSH0 were confirmed accepted by an `eth_call` against mainnet, and an invalid opcode was rejected as a control.

## Oracle
- **The oracle index is a chained product of per-period growth factors, each clamped to `maxRatePerYear` (30%).** A donation spike is discarded permanently rather than merely delayed, which a simple clamp would do.
- **Decreases pass through and flag the source as impaired.** Real losses must reach the floating leg, but new risk on a failing source must stop.
- **Drops below 1e-6 relative are not impairment.** ERC-4626 share prices can tick down by rounding.
- **Ring buffer of 1024 observations, minimum interval 1h, staleness 2 days.** That holds about 42 days at hourly cadence, and lookups are bounded by binary search.
- **Settlement uses the oracle index interpolated at exactly the maturity timestamp, stored once per market.** Every account settles against the same I(T).

## Pricing (RateVAMM)
- **Linear-density concentrated liquidity**: moving the rate by dr fills L·dr notional at the midpoint rate. It is Voltz-style (LP rate ranges, ticks, fee growth) with exact closed-form math and no sqrt-price machinery.
- **1bp ticks over 0–100%, LP range spacing 10bp.** That is fine enough for rates; the bitmap has at most 4 words, so searches are cheap.
- **At most 64 tick crossings per swap**, which keeps every loop bounded. User trades revert on a partial fill; liquidations accept partial fills.
- **LP exposure is accrued through growth-inside accumulators (Uniswap v3 style)**, so an LP's exposure costs O(1) to compute regardless of trade count.
- **Rounding always goes against the trader / LP claim**, so the protocol never pays out more than it holds.
- **Fee = notional × 30bp × time-to-maturity, 80% to LPs and 20% to the protocol.** The fee is proportional to the duration of the rate exposure sold.

## Positions, margin and liquidation
- **Positions are stored as `varShares = Σ dv/I(t)` and `fixedCash = Σ −dv(1+r·τ)`.** Settlement is `varShares·I(T) + fixedCash`, which is linear, so counterparties cancel exactly.
- **Margin is isolated per (market, account)**, which keeps checks bounded and contagion local.
- **IM = 300bp × exposure × max(τ, 1 day) + 5 USDG; MM = 150bp × exposure × max(τ, 1 day) + 2.5 USDG.** A 3% annual rate shock covers historical USDG lending-rate moves; the flat floor pays for liquidation gas.
- **LP margin assumes the whole range fills** (conservative worst case).
- **Daily mark-to-market uses the vAMM TWAP since the previous mark.** Liquidations use the TWAP mark; new risk must clear IM under both mark and spot, so single-block spot manipulation can neither liquidate others nor over-lever oneself.
- **Risk-reducing trades skip the IM check**, so underwater users can always close.
- **The liquidation reward is 10% of the maintenance requirement, and it is paid only while there is exposure to unwind.** Without the exposure condition, keepers could repeatedly skim margin from a fully unwound insolvent account (bug found by an invariant test, fixed).
- **Bad debt at settlement is absorbed by the insurance fund (20% of protocol fees); any residue is recorded as `deficit`.** Losses are explicit and visible rather than silently socialised.
- **Open interest is capped at 40% of source TVL (gross, both sides).** This makes donation attacks unprofitable: inflating the index costs more than the swap could gain.
- **USDG depeg or staleness blocks new risk only.** Margin and PnL are both in USDG, so price only matters as a circuit breaker.

## Fixed-rate vault
- **Each deposit posts 5% as margin, puts 95% into the source, and enters a receive-fixed swap on the same 95% notional.** The floating income and the floating leg cancel exactly, leaving a fixed outcome; a test shows 1% vs 12% floating paths end within 0.05% of each other.
- **No withdrawals before maturity; shares are transferable ERC-20s.** Early exit would require an unwind at market prices and expose remaining holders to slippage. Holders who need liquidity can sell the shares.
- **Vaults exist only for steakUSDG and spUSDG**, which have instant-liquidity ERC-4626 deposits; syrupUSDG is a bridged token.
- **`_decimalsOffset = 6`** to resist share-inflation attacks.

## Governance, security and operations
- **Every admin role sits behind a 48h TimelockController whose minimum delay cannot be lowered below 48h.** The deployer renounces everything, and the script asserts this.
- **The guardian can pause instantly; only the Timelock can unpause.** A compromised guardian can delay users but cannot unlock anything.
- **Pause blocks trade, mint, burn, withdraw and liquidate, but never deposits or settlement.** Users can always top up and always settle.
- **Markets are minimal clones created by MarketFactory, a Timelock action.** New maturities and sources (what $SWPL stakers vote on) are cheap to add.
- **LPPositions is a singleton keyed by market**, with at most 8 ranges per account per market, which bounds margin loops.
- **No ERC-20 is deployed.** $SWPL launches elsewhere; ProjectTokenHooks takes it through a one-shot, Timelock-only `setProjectToken`.
- **Advisory votes: the unstake cooldown (7d) is longer than the voting period (5d).** The same tokens cannot vote twice through another address.
- **ComplianceRegistry is off by default and gates only entry actions.** Exits are never gated.
- **Slither suppressions use `slither.db.json` (triage DB).** Slither 0.11.6 ignores inline `slither-disable` comments on Windows paths; each triaged item is justified in SLITHER_TRIAGE.md.
- **The keeper signs through `cast send --account swapline-keeper`** and never handles key material.
- **The local fork uses port 18546, a renamed anvil binary and `--hardfork cancun`.** Ports 8545–8549 were taken on the build machine, other tooling kills `anvil.exe`, and the non-archive RPC cannot serve the Prague block-hash system call.
- **The TypeScript reference runs directly on Node 24 (type stripping).** There is no build step, and Foundry FFI calls it as `node file.ts`.

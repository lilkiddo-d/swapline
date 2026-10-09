# Swapline

Interest-rate swaps on **Robinhood Chain** (chain id 4663): trade fixed vs floating on tokenized money-market,
RWA-credit and on-chain lending yields. Floating rates come only from on-chain exchange-rate growth. A Voltz-style
vAMM quotes fixed rates per source and maturity, and LPs provide liquidity in rate ranges and earn fees. A
fixed-rate ERC-4626 vault lets ordinary users lock a rate in one deposit.

**Deploying? Read [DEPLOY.md](DEPLOY.md).** It covers keystore import, the single deploy-and-verify command,
`setProjectToken`, the keeper, and Vercel.

## Rate sources (each verified on-chain, 2026-10-09)
| Key | What | Index from | Address |
|---|---|---|---|
| steakUSDG | Steakhouse USDG, Morpho Vault V2 (lending) | `convertToAssets` | `0xBeEff033F34C046626B8D0A041844C5d1A5409dd` |
| spUSDG | Spark Savings USDG (Sky savings rate) | `nowChi()` | `0xde770c84FE66E063336b31737cFE9790f18c4087` |
| syrupUSDG | Maple syrupUSDG (institutional credit, bridged) | Maple exchange-rate feed | `0xDd194C66aDcb422F188a04434e4824D70c151cF0` |

Margin is USDG (`0x5fc5…d168`). The collateral oracle is Chainlink USDG/USD. Every address, with its source link, is
in [config/chains.ts](config/chains.ts) and [config/robinhood.json](config/robinhood.json).

**Gaps on Robinhood Chain:**
- No tokenized T-bill fund (BUIDL, USTB, OUSG, USDY, BENJI) is deployed yet. `ChainlinkRateSource` takes a NAV feed
  when one is issued.
- There is no sequencer uptime feed; the check is pluggable.

## Layout
```
contracts/   Foundry, Solidity 0.8.28 (^0.8.24), OpenZeppelin v5.4, PRBMath v4.1
  src/oracle      RateOracle (ring buffer, clamped chaining) + ERC4626 / Spark / Chainlink rate sources
  src/core        RateVAMM, SwapMarket, MarginEngine, LPPositions, Liquidator, MarketFactory
  src/vault       FixedRateVault (ERC-4626)
  src/periphery   OracleAdapter (collateral pricing, swappable)
  src/fees        FeeCollector          src/token       ProjectTokenHooks ($SWPL, unset by default)
  src/compliance  ComplianceRegistry (off by default)   src/governance  SwaplineTimelock (48h floor)
  script/         Deploy.s.sol + SwaplineDeployer (shared with tests)
  test/           unit, fuzz (incl. FFI vs TypeScript reference), invariant, fork (mainnet RPC)
app/         Next.js 15 + wagmi/viem + RainbowKit: rates dashboard + curve, trade, positions, LP ranges,
             fixed-rate vault, stake (token-gated), risk disclosure, optional geoblock
scripts/     keeper (oracle snapshots, daily mark-to-market, liquidations), TypeScript rate reference, fork tools
config/      chains.ts + robinhood.json (single source of truth for chain data)
deployments/ <chainId>.json written by Deploy.s.sol
```

## Status
| Check | Result |
|---|---|
| Unit, fuzz and invariant tests | 107 tests pass, including 6 protocol invariants |
| Realised floating rate vs TypeScript reference | matches to the wei (FFI fuzz) |
| Fork tests against the mainnet RPC (real addresses) | 5/5 pass |
| Line coverage, `src/` | ≥ 96.8% for every contract (most at 100%) |
| Slither | 0 High / 0 Medium after triage ([SLITHER_TRIAGE](contracts/SLITHER_TRIAGE.md)) |
| Deploy against a local mainnet fork (`--broadcast`) | succeeds; seeded with trades, liquidity and a vault deposit |
| Mainnet dry run | succeeds (about 50M gas, ≈0.002 ETH) |
| Frontend | builds; verified against the fork |

The invariant suite found and drove fixes for two real bugs:
- LPs burning an emptied tick were credited phantom exposure.
- Keepers could repeatedly skim margin from insolvent accounts that had already been fully unwound.

## Setup
```powershell
pnpm install
```
```powershell
cd contracts; forge install --no-git foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.4.0 PaulRBerg/prb-math@v4.1.0; forge build
```
Only needed if `contracts/lib` is missing.

### Tests
```powershell
cd contracts; forge test --no-match-path "test/fork/*"
```
```powershell
cd contracts; $env:RH_RPC_URL = "https://rpc.mainnet.chain.robinhood.com"; forge test --match-path "test/fork/*"
```
```powershell
cd contracts; forge coverage --report summary --no-match-path "test/fork/*" --no-match-contract RealizedRateReferenceTest
```
```powershell
cd contracts; python -m slither . --config-file slither.config.json
```

### Run locally against a mainnet fork
```powershell
powershell -ExecutionPolicy Bypass -File scripts/fork/start-fork.ps1
```
```powershell
bash scripts/fork/deploy-fork.sh
```
```powershell
cd app; Copy-Item .env.example .env.local; pnpm build; pnpm start
```
To use the fork from a browser wallet, add network `http://127.0.0.1:18546` with chain id 31337. The public RPC is not
an archive node, so restart the fork for each session.

## Docs
- [DEPLOY.md](DEPLOY.md)
- [DECISIONS.md](DECISIONS.md)
- [THREAT_MODEL.md](THREAT_MODEL.md)
- [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md)
- [SLITHER_TRIAGE.md](contracts/SLITHER_TRIAGE.md)

Swapline is independent software and is not affiliated with Robinhood. It is unaudited; get an independent audit
before putting real value at risk.

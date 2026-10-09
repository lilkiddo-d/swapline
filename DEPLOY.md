# Deploying Swapline to Robinhood Chain mainnet

Everything below runs from the repo root in **PowerShell** (Git Bash works too; use `export X=...` instead of
`$env:X = "..."`). Nothing in this repo creates, asks for, stores or prints a private key: deploying signs only via the
Foundry keystore account `swapline-deployer`, and the keeper signs only via `swapline-keeper`.

| | |
|---|---|
| Chain | Robinhood Chain mainnet, chain id **4663**, gas token **ETH** |
| RPC | `https://rpc.mainnet.chain.robinhood.com` (public, rate-limited; an Alchemy URL is faster) |
| Explorers / verifiers | Etherscan v2 (`robin.etherscan.io`, primary; needs a free `ETHERSCAN_API_KEY`). Blockscout (`robinhoodchain.blockscout.com`, keyless fallback). |
| Cost | Dry run on 2026-10-09: about 48.4M gas, about **0.002 ETH**. Fund the deployer with 0.01 ETH for headroom. |

## Before you start

- Install Foundry (`foundryup`), Node ≥ 22.6 and pnpm. Then run `pnpm install` and `cd contracts; forge build`.
- Decide on three addresses. Use a **multisig** (e.g. a Safe) for all of them:
  - `GUARDIAN`: can pause immediately. Unpausing goes through the 48h Timelock.
  - `TIMELOCK_PROPOSER`: the only address that can schedule Timelock operations. Any address can execute them once ready.
  - `TREASURY`: receives the protocol's share of fees.
  
  If unset, all three default to the deployer EOA. The script prints a warning in that case.

## 1. Import the deployer key into an encrypted Foundry keystore (once)

```powershell
cast wallet import swapline-deployer --interactive
```

Paste the key when prompted and choose a password. The key is stored encrypted under `~/.foundry/keystores/`.
Fund the address that `cast wallet address --account swapline-deployer` prints with about 0.01 ETH on Robinhood Chain.

## 2. Deploy, wire, hand admin to the Timelock, and verify (one command)

```powershell
cd contracts; $env:RH_RPC_URL = "https://rpc.mainnet.chain.robinhood.com"; $env:ETHERSCAN_API_KEY = "<your etherscan.io API key>"; $env:GUARDIAN = "0xYourGuardianSafe"; $env:TIMELOCK_PROPOSER = "0xYourGovernanceSafe"; $env:TREASURY = "0xYourTreasurySafe"; forge script script/Deploy.s.sol --rpc-url robinhood --account swapline-deployer --sender (cast wallet address --account swapline-deployer) --broadcast --slow --verify
```

`--verify` uses the `[etherscan] robinhood` entry in `foundry.toml` (Etherscan v2, chain 4663). An Etherscan API key
is not a wallet key: get a free one at etherscan.io/myapikey.

Keyless alternative: replace `--verify` with `--verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/`.
On 2026-10-09 the Blockscout API answered non-browser clients with a Cloudflare 403 from the test machine, so prefer
Etherscan. The deployment itself does not depend on verification succeeding.

What the command does:

- Deploys the Timelock (48h minimum delay, which cannot be lowered), ComplianceRegistry (off), OracleAdapter (USDG/USD Chainlink),
  MarginEngine, LPPositions, MarketFactory, Liquidator, FeeCollector, ProjectTokenHooks (token unset), three
  RateSource+RateOracle pairs (steakUSDG, spUSDG, syrupUSDG), 9 markets (3 sources × 30/91/182 days), and 6
  FixedRateVaults (steakUSDG and spUSDG × 3 maturities).
- Grants `DEFAULT_ADMIN_ROLE` to the Timelock on every contract and **renounces every deployer role**. A postflight
  check reverts the whole script if any admin role is left on the deployer.
- Verifies every contract on Blockscout.
- Writes `deployments/4663.json` and the frontend config `app/src/config/deployments.4663.json`.

If verification is interrupted, re-run the same command with `--resume` in place of `--broadcast`. That retries
verification without sending transactions again.

Want to rehearse first? A simulation signs and sends nothing:

```powershell
cd contracts; $env:RH_RPC_URL = "https://rpc.mainnet.chain.robinhood.com"; forge script script/Deploy.s.sol --rpc-url robinhood --sender (cast wallet address --account swapline-deployer)
```

## 3. After deploy: liquidity

New markets have **no liquidity**, and trades revert until LPs add some. An LP deposits margin, then mints a range.
Ticks are 1bp each, so `200` means 2%. Liquidity `L` is notional per 100% of rate: `L = 1e12` puts 10,000 USDG of
depth in each 1% of the range.

```powershell
$M = "0xMarketAddressFromDeployments"; $ME = "0xMarginEngineAddress"; cast send 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 "approve(address,uint256)" $ME 100000000000 --account swapline-deployer --rpc-url $env:RH_RPC_URL; cast send $ME "deposit(address,address,uint256)" $M (cast wallet address --account swapline-deployer) 100000000000 --account swapline-deployer --rpc-url $env:RH_RPC_URL; cast send $M "mint(int24,int24,uint128)" 200 800 1000000000000 --account swapline-deployer --rpc-url $env:RH_RPC_URL
```

The initial fixed rates were set from live data on 2026-10-09: steakUSDG 4.3%, spUSDG 3.44% and syrupUSDG 4.85%. See
`config/robinhood.json` for the sources. Centre LP ranges on these.

## 4. Start the keeper

The keeper snapshots the rate oracles, runs the daily mark-to-market, and liquidates unhealthy accounts. Without
snapshots for 2 days, an oracle goes unhealthy and new trades are blocked. Settlement always works.

```powershell
cast wallet import swapline-keeper --interactive
```

Fund the keeper address with a little ETH (about 0.005 lasts a long time on this chain), then:

```powershell
$env:RH_RPC_URL = "https://rpc.mainnet.chain.robinhood.com"; $env:DEPLOYMENT = "deployments/4663.json"; pnpm keeper
```

The keeper signs with `cast send --account swapline-keeper`. For unattended runs, cast reads the keystore password from
`ETH_PASSWORD` or from `$env:KEEPER_PASSWORD_FILE`. Keep that file outside the repo; it is never logged.

- Single pass (cron, Task Scheduler): `pnpm --filter @swapline/scripts once`.
- Rehearsal that sends nothing: add `--dry-run`.

## 5. Later: set the $SWPL token (once, through the Timelock)

Swapline deploys **no token**. When $SWPL exists, the `TIMELOCK_PROPOSER` schedules the one-shot setter. After 48h,
anyone can execute it.

```powershell
$TL = "0xTimelock"; $HOOKS = "0xProjectTokenHooks"; $SWPL = "0xTokenAddress"; $DATA = cast calldata "setProjectToken(address)" $SWPL; cast send $TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $HOOKS 0 $DATA 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000001 172800 --account <proposer> --rpc-url $env:RH_RPC_URL
```

48 hours later:

```powershell
cast send $TL "execute(address,uint256,bytes,bytes32,bytes32)" $HOOKS 0 $DATA 0x0000000000000000000000000000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000000000000000000000000001 --account swapline-deployer --rpc-url $env:RH_RPC_URL
```

If the proposer is a Safe, make the same `schedule` call from the Safe Transaction Builder. Then set
`NEXT_PUBLIC_PROJECT_TOKEN` in the frontend. See TOKEN_INTEGRATION.md.

## 6. Frontend on Vercel

Import the repo in Vercel with **Root Directory `app`**. Vercel detects Next.js and pnpm. Then set:

| Variable | Value |
|---|---|
| `NEXT_PUBLIC_CHAIN` | `mainnet` (uses `app/src/config/deployments.4663.json`) |
| `NEXT_PUBLIC_RPC_URL` | optional private RPC (defaults to the public RPC) |
| `NEXT_PUBLIC_WC_PROJECT_ID` | optional WalletConnect project id (injected wallets work without it) |
| `NEXT_PUBLIC_PROJECT_TOKEN` | empty until $SWPL is set (token UI hidden) |
| `NEXT_PUBLIC_BLOCKED_COUNTRIES` | optional ISO codes for the geoblock, e.g. `US,KP,IR` |

Commit `app/src/config/deployments.4663.json` (written by the deploy) before deploying the frontend.

## Local rehearsal against a mainnet fork

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fork/start-fork.ps1
```

```powershell
bash scripts/fork/deploy-fork.sh
```

The fork runs on `http://127.0.0.1:18546` with chain id 31337. `deploy-fork.sh` runs the same `Deploy.s.sol`, then
seeds liquidity, trades and a vault deposit. The public RPC is not an archive node, so a fork goes stale after a few
hours; restart it for each session.

## Emergency

- **Guardian:** `MarginEngine.pause()` blocks trading, minting, burning, withdrawals and liquidations, and
  `pauseMarket(market)` does the same for a single market. Deposits and settlement always stay open.
  `RateOracle.flagImpaired()` halts new risk on a source.
- **Unpausing** (`unpause`, `unpauseMarket`, `clearImpairment`) is a Timelock action and takes 48h.

/**
 * Swapline keeper: oracle rate snapshots, daily mark-to-market, and permissionless liquidations.
 *
 * Reads chain state with viem; every write goes through Foundry's `cast send --account swapline-keeper`, so this
 * process never sees a private key. The keystore password is read by cast from ETH_PASSWORD or the file in
 * KEEPER_PASSWORD_FILE (never logged, never stored by this script).
 *
 *   node scripts/src/keeper.ts all            # loop: snapshot + mark + liquidate
 *   node scripts/src/keeper.ts snapshot       # loop: oracles + marks only
 *   node scripts/src/keeper.ts liquidate      # loop: liquidations only
 *   node scripts/src/keeper.ts all --once     # single pass (cron / CI)
 *   node scripts/src/keeper.ts all --dry-run  # report what would be sent, send nothing
 *
 * Env: RH_RPC_URL (default public RPC), DEPLOYMENT (path to deployments/<chainId>.json, default 4663),
 *      KEEPER_ACCOUNT (default swapline-keeper), KEEPER_PASSWORD_FILE, INTERVAL_SECONDS (default 300),
 *      LIQUIDATION_BATCH (default 20), KEEPER_STATE (default scripts/.keeper-state.<chainId>.json).
 * Accounts are discovered from market events starting at the deployment block (found by binary search on
 * `deployedAt`) and cached in KEEPER_STATE so restarts resume where they left off.
 */
import { execFile } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, parseAbi, parseAbiItem, type Address } from "viem";

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const mode = (args.find((a) => !a.startsWith("--")) ?? "all") as "all" | "snapshot" | "liquidate";
const once = args.includes("--once");
const dryRun = args.includes("--dry-run");

const RPC = process.env.RH_RPC_URL ?? "https://rpc.mainnet.chain.robinhood.com";
const ACCOUNT = process.env.KEEPER_ACCOUNT ?? "swapline-keeper";
const INTERVAL = Number(process.env.INTERVAL_SECONDS ?? 300) * 1000;
const BATCH = Number(process.env.LIQUIDATION_BATCH ?? 20);
const deploymentPath = resolve(process.env.DEPLOYMENT ?? resolve(here, "../../deployments/4663.json"));

interface Deployment {
  chainId: number;
  deployedAt: number;
  deployBlock?: number;
  marginEngine: Address;
  liquidator: Address;
  sources: { key: string; oracle: Address }[];
  markets: { source: string; maturity: number; maturityDays: number; market: Address; vault: Address }[];
}
const dep: Deployment = JSON.parse(readFileSync(deploymentPath, "utf8"));

const client = createPublicClient({ transport: http(RPC, { retryCount: 5, retryDelay: 1500, timeout: 60_000 }) });

const oracleAbi = parseAbi([
  "function snapshotDue() view returns (bool)",
  "function isHealthy() view returns (bool)",
  "function impaired() view returns (bool)",
]);
const meAbi = parseAbi([
  "function marketInfo(address) view returns ((bool registered,(uint256 imShock,uint256 mmShock,uint256 minMargin,uint256 minTau,uint256 liquidationRewardBps,uint256 markInterval) risk,uint256 markRate,uint256 markTime,uint256 markCumulative,uint256 lpFeePool))",
  "function isLiquidatable(address market, address account) view returns (bool)",
]);
const marketAbi = parseAbi(["function maturity() view returns (uint256)"]);
const tradeEvent = parseAbiItem(
  "event Trade(address indexed account, int256 notional, uint256 avgRate, uint256 endRate, uint256 fee, int256 varSharesX18, int256 fixedCashX18)",
);
const liqEvent = parseAbiItem("event LiquidityChanged(address indexed account, int24 lower, int24 upper, int128 delta)");

const log = (...m: unknown[]) => console.log(new Date().toISOString(), ...m);

/** Sends a transaction through the Foundry keystore. Never passes or prints secrets. */
function castSend(to: Address, sig: string, params: string[]): Promise<void> {
  const cmd = ["send", to, sig, ...params, "--rpc-url", RPC, "--account", ACCOUNT];
  if (process.env.KEEPER_PASSWORD_FILE) cmd.push("--password-file", process.env.KEEPER_PASSWORD_FILE);
  if (dryRun) {
    log("[dry-run] cast", ["send", to, sig, ...params].join(" "));
    return Promise.resolve();
  }
  return new Promise((ok, fail) => {
    execFile("cast", cmd, { timeout: 180_000 }, (err, stdout, stderr) => {
      if (err) return fail(new Error(stderr.trim().split("\n").slice(-1)[0] || err.message));
      const tx = /transactionHash\s+(0x[0-9a-f]{64})/i.exec(stdout)?.[1];
      log("sent", sig, "->", to, tx ?? "");
      ok();
    });
  });
}

async function snapshotOracles(): Promise<void> {
  for (const s of dep.sources) {
    const [due, healthy, impaired] = await Promise.all([
      client.readContract({ address: s.oracle, abi: oracleAbi, functionName: "snapshotDue" }),
      client.readContract({ address: s.oracle, abi: oracleAbi, functionName: "isHealthy" }),
      client.readContract({ address: s.oracle, abi: oracleAbi, functionName: "impaired" }),
    ]);
    if (impaired) log(`ALERT oracle ${s.key} is IMPAIRED (source loss or guardian flag) — new risk is halted`);
    else if (!healthy) log(`WARN oracle ${s.key} unhealthy (stale or source read failing)`);
    if (due) await castSend(s.oracle, "snapshot()", []).catch((e) => log(`snapshot ${s.key} failed:`, e.message));
  }
}

async function markMarkets(now: bigint): Promise<void> {
  for (const m of dep.markets) {
    if (BigInt(m.maturity) <= now) continue;
    const info = await client.readContract({
      address: dep.marginEngine,
      abi: meAbi,
      functionName: "marketInfo",
      args: [m.market],
    });
    if (now >= info.markTime + info.risk.markInterval) {
      await castSend(dep.marginEngine, "poke(address)", [m.market]).catch((e) =>
        log(`mark ${m.source}-${m.maturityDays}D failed:`, e.message),
      );
    }
  }
}

/** Accounts are discovered from Trade / LiquidityChanged events (chunked queries, persisted state). */
const statePath = resolve(process.env.KEEPER_STATE ?? resolve(here, `../.keeper-state.${dep.chainId}.json`));
const known = new Map<Address, Set<Address>>();
let scannedTo = 0n;
if (existsSync(statePath)) {
  const st = JSON.parse(readFileSync(statePath, "utf8")) as { scannedTo: string; accounts: Record<string, string[]> };
  scannedTo = BigInt(st.scannedTo);
  for (const [m, accts] of Object.entries(st.accounts)) known.set(m as Address, new Set(accts as Address[]));
}
function saveState(): void {
  const accounts: Record<string, string[]> = {};
  for (const [m, set] of known) accounts[m] = [...set];
  writeFileSync(statePath, JSON.stringify({ scannedTo: scannedTo.toString(), accounts }, null, 1));
}

/** First block with timestamp >= ts (binary search, ~27 reads). */
async function blockAtOrAfter(ts: bigint, head: bigint): Promise<bigint> {
  let lo = 0n;
  let hi = head;
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    const b = await client.getBlock({ blockNumber: mid });
    if (b.timestamp < ts) lo = mid + 1n;
    else hi = mid;
  }
  return lo;
}

async function discoverAccounts(head: bigint): Promise<void> {
  if (scannedTo === 0n) {
    let start: bigint | undefined;
    if (dep.deployBlock !== undefined && BigInt(dep.deployBlock) <= head) {
      // trust the recorded block only if its timestamp matches deployedAt (on Arbitrum-style chains the EVM's
      // block.number can be an L1 estimate, e.g. on a local anvil fork)
      const b = await client.getBlock({ blockNumber: BigInt(dep.deployBlock) });
      const drift = b.timestamp > BigInt(dep.deployedAt) ? b.timestamp - BigInt(dep.deployedAt) : BigInt(dep.deployedAt) - b.timestamp;
      if (drift <= 600n) start = BigInt(dep.deployBlock);
    }
    if (start === undefined) start = await blockAtOrAfter(BigInt(dep.deployedAt), head);
    scannedTo = start - 1n;
    log(`scanning market events from block ${start}`);
  }
  const from = scannedTo + 1n;
  const step = 100_000n;
  for (let start = from; start <= head; start += step) {
    const end = start + step - 1n > head ? head : start + step - 1n;
    for (const m of dep.markets) {
      const set = known.get(m.market) ?? new Set<Address>();
      for (const ev of [tradeEvent, liqEvent]) {
        const logs = await client.getLogs({ address: m.market, event: ev, fromBlock: start, toBlock: end });
        for (const l of logs) if (l.args.account) set.add(l.args.account);
      }
      known.set(m.market, set);
    }
    scannedTo = end;
    saveState();
  }
}

async function liquidate(now: bigint): Promise<void> {
  for (const m of dep.markets) {
    if (BigInt(m.maturity) <= now) continue;
    const accounts = [...(known.get(m.market) ?? [])];
    const unhealthy: Address[] = [];
    for (const a of accounts) {
      const liq = await client.readContract({
        address: dep.marginEngine,
        abi: meAbi,
        functionName: "isLiquidatable",
        args: [m.market, a],
      });
      if (liq) unhealthy.push(a);
    }
    for (let i = 0; i < unhealthy.length; i += BATCH) {
      const batch = unhealthy.slice(i, i + BATCH);
      log(`liquidating ${batch.length} account(s) in ${m.source}-${m.maturityDays}D`);
      await castSend(dep.liquidator, "liquidateMany(address,address[])", [m.market, `[${batch.join(",")}]`]).catch(
        (e) => log("liquidation failed:", e.message),
      );
    }
  }
}

async function tick(): Promise<void> {
  const block = await client.getBlock();
  const now = block.timestamp;
  if (mode === "all" || mode === "snapshot") {
    await snapshotOracles();
    await markMarkets(now);
  }
  if (mode === "all" || mode === "liquidate") {
    await discoverAccounts(block.number);
    await liquidate(now);
  }
}

async function main(): Promise<void> {
  const chainId = await client.getChainId();
  if (chainId !== dep.chainId) throw new Error(`RPC chain ${chainId} != deployment chain ${dep.chainId}`);
  log(`keeper ${mode}${once ? " (once)" : ""}${dryRun ? " (dry-run)" : ""} on chain ${chainId}, account ${ACCOUNT}`);
  for (;;) {
    try {
      await tick();
    } catch (e) {
      log("tick error:", (e as Error).message);
    }
    if (once) break;
    await new Promise((r) => setTimeout(r, INTERVAL));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});

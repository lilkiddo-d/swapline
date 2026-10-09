"use client";

import { useState } from "react";
import { useReadContracts } from "wagmi";
import { deployment, marketLabel } from "@/lib/deployment";
import { erc20Abi, lpPositionsAbi, marginEngineAbi, marketAbi } from "@/lib/abis";
import { useConnected, useMarkets, useTx } from "@/lib/hooks";
import { pct, usd, parseUsd } from "@/lib/format";
import { MarketSelect, PendingDeployment, RiskGate } from "@/components/common";

const SPACING = 10; // ticks (10bp)

/** depth per 1% of rate (USDG) -> liquidity L (token units per 100% of rate) */
function depthToL(depthPerPct: bigint): bigint {
  return depthPerPct * 100n;
}

export default function ProvideLiquidity() {
  const account = useConnected();
  const { send, status, busy } = useTx();
  const { data: markets } = useMarkets();
  const [mi, setMi] = useState(1);
  const [lo, setLo] = useState("3.0");
  const [hi, setHi] = useState("6.0");
  const [depth, setDepth] = useState("5000");
  const [margin, setMargin] = useState("2000");
  const m = deployment.markets[mi];

  const lower = Math.round((Number(lo) * 100) / SPACING) * SPACING;
  const upper = Math.round((Number(hi) * 100) / SPACING) * SPACING;
  const L = depthToL(parseUsd(depth));
  const capacity = upper > lower ? (L * BigInt(upper - lower)) / 10_000n : 0n;
  const validRange = lower >= 0 && upper <= 10_000 && upper > lower;

  const { data, refetch } = useReadContracts({
    contracts: [
      { address: deployment.lpPositions, abi: lpPositionsAbi, functionName: "positionsOf", args: [m?.market, account!] },
      { address: deployment.stablecoin, abi: erc20Abi, functionName: "allowance", args: [account!, deployment.marginEngine] },
      { address: deployment.marginEngine, abi: marginEngineAbi, functionName: "marginOf", args: [m?.market, account!] },
      { address: m?.market, abi: marketAbi, functionName: "accountState", args: [account!] },
    ],
    query: { enabled: !!account && !!m },
    allowFailure: true,
  });
  const positions = (data?.[0]?.result ?? []) as readonly { lower: number; upper: number; liquidity: bigint }[];
  const allowance = (data?.[1]?.result as bigint | undefined) ?? 0n;
  const marginNow = data?.[2]?.result as bigint | undefined;
  const fees = (data?.[3]?.result as { lpFeesOwed: bigint } | undefined)?.lpFeesOwed;

  async function provide() {
    if (!account || !validRange || L === 0n) return;
    const add = parseUsd(margin);
    if (add > 0n) {
      if (allowance < add && !(await send("Approve USDG", { address: deployment.stablecoin, abi: erc20Abi, functionName: "approve", args: [deployment.marginEngine, add] }))) return;
      if (!(await send("Deposit margin", { address: deployment.marginEngine, abi: marginEngineAbi, functionName: "deposit", args: [m.market, account, add] }))) return;
    }
    await send("Add liquidity", { address: m.market, abi: marketAbi, functionName: "mint", args: [lower, upper, L] });
    refetch();
  }

  if (!m) return <PendingDeployment />;
  return (
    <>
      <h1>Provide liquidity</h1>
      <p className="sub">
        LPs quote fixed rates inside a range and earn 80% of trading fees. When traders trade against your range you take
        the opposite side of their swaps, so you need margin for the worst case (the whole range filled).
      </p>
      <RiskGate>
        <div className="grid">
          <div className="panel">
            <label>Market</label>
            <MarketSelect value={mi} onChange={setMi} />
            <p className="muted small">Current fixed rate: <b>{pct(markets[mi]?.rate)}</b> · floating (7d): {pct(markets[mi]?.floating)}</p>
            <div className="row">
              <div style={{ flex: 1 }}><label>Lower rate (%)</label><input value={lo} onChange={(e) => setLo(e.target.value)} /></div>
              <div style={{ flex: 1 }}><label>Upper rate (%)</label><input value={hi} onChange={(e) => setHi(e.target.value)} /></div>
            </div>
            <label>Depth per 1% of rate move (USDG notional)</label>
            <input value={depth} onChange={(e) => setDepth(e.target.value)} />
            <label>Add margin (USDG)</label>
            <input value={margin} onChange={(e) => setMargin(e.target.value)} />
            <p className="muted small">
              Range {(lower / 100).toFixed(2)}%–{(upper / 100).toFixed(2)}% (10bp steps) · max notional you can take:{" "}
              <b>{usd(capacity, 0)} USDG</b>
            </p>
            <button disabled={!account || busy || !validRange || L === 0n} onClick={provide}>{account ? "Add liquidity" : "Connect wallet"}</button>
            <div className="status">{status}</div>
          </div>
          <div className="panel">
            <h2>Your ranges in {marketLabel(m)}</h2>
            <p className="muted small">Margin: {usd(marginNow)} USDG · uncollected fees: {usd(fees)} USDG</p>
            {positions.length === 0 ? (
              <p className="muted">No ranges yet.</p>
            ) : (
              <table>
                <thead><tr><th>Range</th><th>Depth / 1%</th><th></th></tr></thead>
                <tbody>
                  {positions.map((p) => (
                    <tr key={`${p.lower}-${p.upper}`}>
                      <td>{(p.lower / 100).toFixed(2)}%–{(p.upper / 100).toFixed(2)}%</td>
                      <td>{usd(p.liquidity / 100n, 0)}</td>
                      <td className="row">
                        <button className="ghost" disabled={busy} onClick={async () => { await send("Collect", { address: m.market, abi: marketAbi, functionName: "collect", args: [p.lower, p.upper] }); refetch(); }}>Collect</button>
                        <button className="ghost" disabled={busy} onClick={async () => { await send("Remove", { address: m.market, abi: marketAbi, functionName: "burn", args: [p.lower, p.upper, p.liquidity] }); refetch(); }}>Remove</button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </div>
      </RiskGate>
    </>
  );
}

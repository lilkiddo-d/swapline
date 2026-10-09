"use client";

import { Suspense, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { useReadContracts } from "wagmi";
import { deployment, marketLabel } from "@/lib/deployment";
import { erc20Abi, marginEngineAbi, marketAbi, vammAbi } from "@/lib/abis";
import { useConnected, useMarkets, useTx } from "@/lib/hooks";
import { pct, usd, parseUsd, parsePct, WAD } from "@/lib/format";
import { MarketSelect, PendingDeployment, RiskGate, HealthBar } from "@/components/common";

function TradeInner() {
  const params = useSearchParams();
  const [mi, setMi] = useState(Number(params.get("m") ?? 1) || 0);
  const [side, setSide] = useState<"pay" | "recv">("pay");
  const [notional, setNotional] = useState("10000");
  const [margin, setMargin] = useState("500");
  const [slip, setSlip] = useState("0.50");
  const account = useConnected();
  const { send, status, busy } = useTx();
  const { data: markets } = useMarkets();
  const m = deployment.markets[mi];
  const md = markets[mi];

  const { data, refetch } = useReadContracts({
    contracts: [
      { address: m?.vamm, abi: vammAbi, functionName: "liquidity" },
      { address: m?.market, abi: marketAbi, functionName: "tau" },
      { address: m?.market, abi: marketAbi, functionName: "params" },
      { address: deployment.stablecoin, abi: erc20Abi, functionName: "allowance", args: [account!, deployment.marginEngine] },
      { address: deployment.stablecoin, abi: erc20Abi, functionName: "balanceOf", args: [account!] },
      { address: deployment.marginEngine, abi: marginEngineAbi, functionName: "marginOf", args: [m?.market, account!] },
      { address: deployment.marginEngine, abi: marginEngineAbi, functionName: "health", args: [m?.market, account!] },
    ],
    query: { enabled: !!m },
    allowFailure: true,
  });
  const L = data?.[0]?.result as bigint | undefined;
  const tau = data?.[1]?.result as bigint | undefined;
  const feeRate = (data?.[2]?.result as readonly bigint[] | undefined)?.[0];
  const allowance = (data?.[3]?.result as bigint | undefined) ?? 0n;
  const wallet = data?.[4]?.result as bigint | undefined;
  const marginNow = data?.[5]?.result as bigint | undefined;
  const health = data?.[6]?.result as { equity: bigint; initialRequirement: bigint; maintenanceRequirement: bigint } | undefined;

  const n = parseUsd(notional);
  const add = parseUsd(margin);
  const quote = useMemo(() => {
    const r = md?.rate;
    if (r === undefined || !L || L === 0n || n === 0n) return undefined;
    const move = (n * WAD) / L; // linear-density curve within the active range
    const end = side === "pay" ? r + move : r > move ? r - move : 0n;
    const avg = (r + end) / 2n;
    const fee = feeRate !== undefined && tau !== undefined ? (n * feeRate * tau) / WAD / WAD : undefined;
    const limit = side === "pay" ? end + parsePct(slip) : end > parsePct(slip) ? end - parsePct(slip) : 0n;
    return { end, avg, fee, limit };
  }, [md?.rate, L, n, side, slip, feeRate, tau]);

  async function submit() {
    if (!account || !quote) return;
    if (add > 0n) {
      if (allowance < add) {
        const ok = await send("Approve USDG", { address: deployment.stablecoin, abi: erc20Abi, functionName: "approve", args: [deployment.marginEngine, add] });
        if (!ok) return;
      }
      const ok = await send("Deposit margin", { address: deployment.marginEngine, abi: marginEngineAbi, functionName: "deposit", args: [m.market, account, add] });
      if (!ok) return;
    }
    const signed = side === "pay" ? n : -n;
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
    await send(side === "pay" ? "Pay fixed" : "Receive fixed", { address: m.market, abi: marketAbi, functionName: "trade", args: [signed, quote.limit, deadline] });
    refetch();
  }

  if (!m) return <PendingDeployment />;
  return (
    <>
      <h1>Trade</h1>
      <p className="sub">
        <b>Pay fixed</b> = you pay the fixed rate and receive the floating rate of the source (profits if rates rise).{" "}
        <b>Receive fixed</b> = the opposite (locks in a rate). Cashflows net at maturity; you can close any time by trading
        the other side.
      </p>
      <RiskGate>
        <div className="grid">
          <div className="panel">
            <label>Market</label>
            <MarketSelect value={mi} onChange={setMi} />
            <label>Side</label>
            <div className="seg">
              <button className={side === "pay" ? "on-pay" : ""} onClick={() => setSide("pay")}>Pay fixed</button>
              <button className={side === "recv" ? "on-recv" : ""} onClick={() => setSide("recv")}>Receive fixed</button>
            </div>
            <label>Notional (USDG)</label>
            <input value={notional} onChange={(e) => setNotional(e.target.value)} inputMode="decimal" />
            <label>Add margin (USDG) — wallet {usd(wallet)}</label>
            <input value={margin} onChange={(e) => setMargin(e.target.value)} inputMode="decimal" />
            <label>Max slippage (percentage points of rate)</label>
            <input value={slip} onChange={(e) => setSlip(e.target.value)} inputMode="decimal" />
            <div className="row" style={{ marginTop: 16 }}>
              <button className={side === "pay" ? "pay" : "recv"} disabled={!account || !quote || busy} onClick={submit}>
                {!account ? "Connect wallet" : side === "pay" ? "Pay fixed" : "Receive fixed"}
              </button>
            </div>
            <div className="status">{status}</div>
          </div>
          <div className="panel">
            <h2>{marketLabel(m)}</h2>
            <table>
              <tbody>
                <tr><td className="muted">Floating (7d)</td><td>{pct(md?.floating)}</td></tr>
                <tr><td className="muted">Implied fixed now</td><td>{pct(md?.rate)}</td></tr>
                <tr><td className="muted">Est. average execution</td><td>{pct(quote?.avg)}</td></tr>
                <tr><td className="muted">Est. rate after trade</td><td>{pct(quote?.end)}</td></tr>
                <tr><td className="muted">Worst accepted rate</td><td>{pct(quote?.limit)}</td></tr>
                <tr><td className="muted">Fee (est.)</td><td>{usd(quote?.fee)} USDG</td></tr>
                <tr><td className="muted">Your margin here</td><td>{usd(marginNow)} USDG</td></tr>
                <tr><td className="muted">Health</td><td><HealthBar equity={health?.equity} im={health?.initialRequirement} mm={health?.maintenanceRequirement} /></td></tr>
              </tbody>
            </table>
            <p className="muted small" style={{ marginTop: 10 }}>
              Estimates assume the trade stays inside the current liquidity range; the on-chain limit protects you if it
              does not. Initial margin ≈ notional × 3% × years to maturity + 5 USDG.
            </p>
          </div>
        </div>
      </RiskGate>
    </>
  );
}

export default function TradePage() {
  return (
    <Suspense>
      <TradeInner />
    </Suspense>
  );
}

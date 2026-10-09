"use client";

import { useState } from "react";
import { useReadContracts } from "wagmi";
import { deployment, marketLabel, sourceOf } from "@/lib/deployment";
import { marginEngineAbi, marketAbi, oracleAbi } from "@/lib/abis";
import { useConnected, useTx } from "@/lib/hooks";
import { usd, parseUsd, date } from "@/lib/format";
import { HealthBar, PendingDeployment } from "@/components/common";

type State = { varSharesX18: bigint; fixedCashX18: bigint; lpUnfilledNotional: bigint; lpFeesOwed: bigint; hasPosition: boolean };
type Health = { equity: bigint; initialRequirement: bigint; maintenanceRequirement: bigint; exposure: bigint };

export default function Positions() {
  const account = useConnected();
  const { send, status, busy } = useTx();
  const [withdrawAmt, setWithdrawAmt] = useState<Record<string, string>>({});
  const per = 5;
  const { data, refetch } = useReadContracts({
    contracts: deployment.markets.flatMap((m) => [
      { address: m.market, abi: marketAbi, functionName: "accountState", args: [account!] },
      { address: deployment.marginEngine, abi: marginEngineAbi, functionName: "marginOf", args: [m.market, account!] },
      { address: deployment.marginEngine, abi: marginEngineAbi, functionName: "health", args: [m.market, account!] },
      { address: m.market, abi: marketAbi, functionName: "settled", args: [account!] },
      { address: sourceOf(m)!.oracle, abi: oracleAbi, functionName: "currentIndex" },
    ] as const),
    query: { enabled: !!account },
    allowFailure: true,
  });

  const rows = deployment.markets
    .map((m, i) => {
      const r = (k: number) => data?.[i * per + k]?.result as unknown;
      const s = r(0) as State | undefined;
      const margin = r(1) as bigint | undefined;
      return { m, s, margin, h: r(2) as Health | undefined, settled: r(3) as boolean | undefined, index: r(4) as bigint | undefined };
    })
    .filter((x) => (x.s?.hasPosition ?? false) || (x.margin ?? 0n) > 0n);

  const now = Date.now() / 1000;

  async function close(row: (typeof rows)[number]) {
    if (!row.s || !row.index) return;
    const notional = -((row.s.varSharesX18 * row.index) / 10n ** 36n);
    if (notional === 0n) return;
    const deadline = BigInt(Math.floor(now) + 600);
    const limit = notional > 0n ? 10n ** 18n : 0n; // close at market; user can use the Trade page for a tighter limit
    await send("Close position", { address: row.m.market, abi: marketAbi, functionName: "trade", args: [notional, limit, deadline] });
    refetch();
  }

  return (
    <>
      <h1>Positions</h1>
      <p className="sub">
        Equity = margin + mark-to-market value (marked daily against the market&apos;s time-weighted fixed rate). Below
        maintenance margin a position can be liquidated by anyone.
      </p>
      <PendingDeployment />
      {!account ? (
        <div className="panel">Connect a wallet to see your positions.</div>
      ) : rows.length === 0 ? (
        <div className="panel">No positions or margin yet. Open one on the <a href="/trade">Trade</a> page.</div>
      ) : (
        <div className="panel scroll">
          <table>
            <thead>
              <tr><th>Market</th><th>Direction</th><th>Notional</th><th>Margin</th><th>Equity</th><th>Health</th><th>Actions</th></tr>
            </thead>
            <tbody>
              {rows.map((row) => {
                const vs = row.s?.varSharesX18 ?? 0n;
                const notional = row.index ? (vs * row.index) / 10n ** 36n : 0n;
                const matured = now >= row.m.maturity;
                return (
                  <tr key={row.m.market}>
                    <td>{marketLabel(row.m)}<div className="muted small">matures {date(row.m.maturity)}</div></td>
                    <td>{vs > 0n ? <span style={{ color: "var(--pay)" }}>Pay fixed</span> : vs < 0n ? <span style={{ color: "var(--recv)" }}>Receive fixed</span> : <span className="muted">flat</span>}
                      {(row.s?.lpUnfilledNotional ?? 0n) > 0n && <div className="muted small">LP range active</div>}</td>
                    <td>{usd(notional < 0n ? -notional : notional)}</td>
                    <td>{usd(row.margin)}</td>
                    <td>{usd(row.h?.equity)}</td>
                    <td><HealthBar equity={row.h?.equity} im={row.h?.initialRequirement} mm={row.h?.maintenanceRequirement} /></td>
                    <td>
                      <div className="row">
                        {!matured && vs !== 0n && <button className="ghost" disabled={busy} onClick={() => close(row)}>Close</button>}
                        {matured && row.s?.hasPosition && !row.settled && (
                          <button disabled={busy} onClick={async () => { await send("Settle", { address: row.m.market, abi: marketAbi, functionName: "settle", args: [account] }); refetch(); }}>Settle</button>
                        )}
                        <input style={{ width: 110 }} placeholder="amount" value={withdrawAmt[row.m.market] ?? ""}
                          onChange={(e) => setWithdrawAmt({ ...withdrawAmt, [row.m.market]: e.target.value })} />
                        <button className="ghost" disabled={busy || parseUsd(withdrawAmt[row.m.market] ?? "") === 0n}
                          onClick={async () => { await send("Withdraw margin", { address: deployment.marginEngine, abi: marginEngineAbi, functionName: "withdraw", args: [row.m.market, parseUsd(withdrawAmt[row.m.market] ?? ""), account] }); refetch(); }}>
                          Withdraw
                        </button>
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <div className="status">{status}</div>
        </div>
      )}
    </>
  );
}

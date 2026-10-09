"use client";

import Link from "next/link";
import { useMarkets, type MarketData } from "@/lib/hooks";
import { deployment, network } from "@/lib/deployment";
import { pct, date } from "@/lib/format";
import { PendingDeployment } from "@/components/common";

const COLORS = ["#5b8cff", "#3ecf8e", "#ff8a5b", "#c38bff"];

function Curve({ data }: { data: MarketData[] }) {
  const sources = deployment.sources.map((s) => s.key);
  const W = 640, H = 240, P = 36;
  const all = data.flatMap((d) => [d.rate ?? 0n, d.floating ?? 0n]).map((x) => Number(x) / 1e16);
  const maxY = Math.max(1, Math.ceil(Math.max(...all, 0) + 1));
  const days = [...new Set(data.map((d) => d.m.maturityDays))].sort((a, b) => a - b);
  const maxX = Math.max(...days, 1);
  const x = (dd: number) => P + (dd / maxX) * (W - 2 * P);
  const y = (v: number) => H - P - (v / maxY) * (H - 2 * P);
  return (
    <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img" aria-label="Implied fixed-rate curve by source">
      {[0, 0.25, 0.5, 0.75, 1].map((f) => (
        <g key={f}>
          <line x1={P} x2={W - P} y1={y(maxY * f)} y2={y(maxY * f)} stroke="#243049" />
          <text x={4} y={y(maxY * f) + 4} fill="#8b97ad" fontSize="11">{(maxY * f).toFixed(1)}%</text>
        </g>
      ))}
      {days.map((dd) => (
        <text key={dd} x={x(dd)} y={H - 10} fill="#8b97ad" fontSize="11" textAnchor="middle">{dd}D</text>
      ))}
      {sources.map((s, si) => {
        const pts = data.filter((d) => d.m.source === s && d.rate !== undefined).sort((a, b) => a.m.maturityDays - b.m.maturityDays);
        const fl = data.find((d) => d.m.source === s)?.floating;
        const c = COLORS[si % COLORS.length];
        return (
          <g key={s}>
            {fl !== undefined && (
              <line x1={P} x2={W - P} y1={y(Number(fl) / 1e16)} y2={y(Number(fl) / 1e16)} stroke={c} strokeDasharray="4 4" opacity={0.6} />
            )}
            <polyline fill="none" stroke={c} strokeWidth={2.5}
              points={pts.map((d) => `${x(d.m.maturityDays)},${y(Number(d.rate) / 1e16)}`).join(" ")} />
            {pts.map((d) => <circle key={d.m.market} cx={x(d.m.maturityDays)} cy={y(Number(d.rate) / 1e16)} r={4} fill={c} />)}
          </g>
        );
      })}
    </svg>
  );
}

export default function Dashboard() {
  const { data, isLoading } = useMarkets();
  return (
    <>
      <h1>Rates</h1>
      <p className="sub">
        Floating rates come only from on-chain exchange-rate growth of each source (trailing 7 days). Implied fixed rates
        are what the market will pay or receive today for each maturity.
      </p>
      <PendingDeployment />
      <div className="grid">
        {deployment.sources.map((s, si) => {
          const rows = data.filter((d) => d.m.source === s.key);
          const fl = rows[0]?.floating;
          const health = rows[0]?.impaired ? "bad" : rows[0]?.healthy === false ? "warn" : "ok";
          return (
            <div className="panel" key={s.key}>
              <div className="row" style={{ justifyContent: "space-between" }}>
                <h2 style={{ margin: 0, color: COLORS[si % COLORS.length] }}>{s.key}</h2>
                <span className={`pill ${health}`}>{health === "ok" ? "oracle healthy" : health === "warn" ? "oracle stale" : "impaired"}</span>
              </div>
              <p className="muted small" style={{ minHeight: 40 }}>{s.description}</p>
              <div className="muted small">Floating (7d)</div>
              <div className="kpi">{isLoading ? "…" : pct(fl)}</div>
              <table style={{ marginTop: 10 }}>
                <thead><tr><th>Maturity</th><th>Fixed</th><th>Spread</th></tr></thead>
                <tbody>
                  {rows.map((d) => (
                    <tr key={d.m.market}>
                      <td><Link href={`/trade?m=${deployment.markets.indexOf(d.m)}`}>{d.m.maturityDays}D</Link> <span className="muted small">{date(d.m.maturity)}</span></td>
                      <td>{pct(d.rate)}</td>
                      <td className="muted">{d.rate !== undefined && fl !== undefined ? pct(d.rate - fl) : "—"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          );
        })}
      </div>
      <div className="panel" style={{ marginTop: 16 }}>
        <h2>Fixed-rate curve</h2>
        <div className="legend" style={{ marginBottom: 8 }}>
          {deployment.sources.map((s, si) => (
            <span key={s.key}><i style={{ background: COLORS[si % COLORS.length] }} />{s.key} (solid: implied fixed, dashed: floating)</span>
          ))}
        </div>
        <Curve data={data} />
      </div>
      <p className="muted small" style={{ marginTop: 16 }}>
        Network: {network === "mainnet" ? "Robinhood Chain mainnet (4663)" : "local mainnet fork (31337)"}.
      </p>
    </>
  );
}

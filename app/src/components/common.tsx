"use client";

import Link from "next/link";
import { deployment, marketLabel, type MarketDeployment } from "@/lib/deployment";
import { useRiskAck } from "@/lib/hooks";

export function MarketSelect({ value, onChange, vaultsOnly = false }: {
  value: number;
  onChange: (i: number) => void;
  vaultsOnly?: boolean;
}) {
  return (
    <select value={value} onChange={(e) => onChange(Number(e.target.value))}>
      {deployment.markets.map((m, i) =>
        vaultsOnly && m.vault === "0x0000000000000000000000000000000000000000" ? null : (
          <option key={m.market} value={i}>
            {marketLabel(m)} — matures {new Date(m.maturity * 1000).toISOString().slice(0, 10)}
          </option>
        ),
      )}
    </select>
  );
}

export function PendingDeployment() {
  if (!deployment.pending && deployment.markets.length > 0) return null;
  return (
    <div className="notice">
      No deployment found for this network yet. Run the deploy (see DEPLOY.md); it writes
      <code> app/src/config/deployments.&lt;chainId&gt;.json</code>.
    </div>
  );
}

/** Blocks risk-taking actions until the user has read and acknowledged the risk disclosure. */
export function RiskGate({ children }: { children: React.ReactNode }) {
  const [ack, setAck] = useRiskAck();
  if (ack) return <>{children}</>;
  return (
    <div className="notice">
      Interest-rate swaps are leveraged and can lose more than the margin you post. Read the{" "}
      <Link href="/risk">risk disclosure</Link> first.
      <div className="row" style={{ marginTop: 10 }}>
        <button className="ghost" onClick={() => setAck(true)}>
          I have read and understood the risks
        </button>
      </div>
    </div>
  );
}

export function HealthBar({ equity, mm, im }: { equity?: bigint; mm?: bigint; im?: bigint }) {
  if (equity === undefined || im === undefined || mm === undefined || im === 0n) return <span className="muted">—</span>;
  const ratio = Number(equity) / Number(im);
  const color = equity < mm ? "var(--bad)" : equity < im ? "var(--warn)" : "var(--recv)";
  const label = equity < mm ? "liquidatable" : equity < im ? "below initial" : "healthy";
  return (
    <div style={{ minWidth: 140 }}>
      <div className="bar">
        <div style={{ width: `${Math.max(4, Math.min(100, ratio * 50))}%`, background: color }} />
      </div>
      <span className="small" style={{ color }}>
        {label} · {ratio.toFixed(2)}× IM
      </span>
    </div>
  );
}

export type { MarketDeployment };

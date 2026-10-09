"use client";

import { useState } from "react";
import { useReadContracts } from "wagmi";
import { formatUnits, parseUnits } from "viem";
import { deployment, projectToken, tokenFeaturesEnabled, ZERO } from "@/lib/deployment";
import { erc20Abi, hooksAbi } from "@/lib/abis";
import { useConnected, useTx } from "@/lib/hooks";
import { usd } from "@/lib/format";

const KINDS = ["New rate source", "New maturity", "Parameter change", "Other"];

/** Shown only when NEXT_PUBLIC_PROJECT_TOKEN is set (see TOKEN_INTEGRATION.md). */
export default function Stake() {
  const account = useConnected();
  const { send, status, busy } = useTx();
  const [amount, setAmount] = useState("100");
  const hooks = deployment.projectTokenHooks;
  const token = (projectToken || ZERO) as `0x${string}`;
  const { data, refetch } = useReadContracts({
    contracts: [
      { address: hooks, abi: hooksAbi, functionName: "tokenSet" },
      { address: hooks, abi: hooksAbi, functionName: "totalStaked" },
      { address: hooks, abi: hooksAbi, functionName: "stakeOf", args: [account ?? ZERO] },
      { address: hooks, abi: hooksAbi, functionName: "earned", args: [account ?? ZERO] },
      { address: hooks, abi: hooksAbi, functionName: "pendingUnstake", args: [account ?? ZERO] },
      { address: token, abi: erc20Abi, functionName: "allowance", args: [account ?? ZERO, hooks] },
      { address: hooks, abi: hooksAbi, functionName: "proposalCount" },
    ],
    query: { enabled: tokenFeaturesEnabled },
    allowFailure: true,
  });
  const r = (k: number) => data?.[k]?.result as unknown;
  const count = Number((r(6) as bigint | undefined) ?? 0n);
  const ids = Array.from({ length: Math.min(count, 20) }, (_, k) => BigInt(count - 1 - k));
  const { data: props } = useReadContracts({
    contracts: ids.map((id) => ({ address: hooks, abi: hooksAbi, functionName: "proposal", args: [id] }) as const),
    query: { enabled: ids.length > 0 },
    allowFailure: true,
  });

  if (!tokenFeaturesEnabled) return <div className="panel">Token features are not enabled.</div>;
  if (r(0) === false) return <div className="panel">The token address is configured in the app but has not been set on-chain yet (Timelock pending).</div>;
  const amt = (() => { try { return parseUnits(amount || "0", 18); } catch { return 0n; } })();
  const pending = r(4) as readonly [bigint, bigint] | undefined;

  return (
    <>
      <h1>Stake $SWPL</h1>
      <p className="sub">Stakers share protocol trading fees (paid in USDG) and vote on new rate sources and maturities (advisory; executed through the 48h Timelock).</p>
      <div className="grid">
        <div className="panel">
          <p>Total staked: <b>{formatUnits((r(1) as bigint) ?? 0n, 18)}</b> · You: <b>{formatUnits((r(2) as bigint) ?? 0n, 18)}</b></p>
          <p>Claimable fees: <b>{usd(r(3) as bigint | undefined)} USDG</b></p>
          {pending && pending[0] > 0n && <p className="muted small">Unstaking {formatUnits(pending[0], 18)} — available {new Date(Number(pending[1]) * 1000).toLocaleString()}</p>}
          <label>Amount</label>
          <input value={amount} onChange={(e) => setAmount(e.target.value)} />
          <div className="row" style={{ marginTop: 12 }}>
            <button disabled={!account || busy || amt === 0n} onClick={async () => {
              if (((r(5) as bigint) ?? 0n) < amt && !(await send("Approve", { address: token, abi: erc20Abi, functionName: "approve", args: [hooks, amt] }))) return;
              await send("Stake", { address: hooks, abi: hooksAbi, functionName: "stake", args: [amt] }); refetch();
            }}>Stake</button>
            <button className="ghost" disabled={!account || busy || amt === 0n} onClick={async () => { await send("Request unstake (7-day cooldown)", { address: hooks, abi: hooksAbi, functionName: "requestUnstake", args: [amt] }); refetch(); }}>Unstake</button>
            <button className="ghost" disabled={!account || busy} onClick={async () => { await send("Withdraw", { address: hooks, abi: hooksAbi, functionName: "withdraw" }); refetch(); }}>Withdraw</button>
            <button className="ghost" disabled={!account || busy} onClick={async () => { await send("Claim fees", { address: hooks, abi: hooksAbi, functionName: "claim" }); refetch(); }}>Claim</button>
          </div>
          <div className="status">{status}</div>
        </div>
        <div className="panel">
          <h2>Advisory proposals</h2>
          {ids.length === 0 ? <p className="muted">None yet.</p> : ids.map((id, k) => {
            const p = props?.[k]?.result as { kind: number; end: bigint; forVotes: bigint; againstVotes: bigint; description: string } | undefined;
            if (!p) return null;
            const open = Date.now() / 1000 < Number(p.end);
            return (
              <div key={id.toString()} style={{ borderBottom: "1px solid var(--border)", padding: "10px 0" }}>
                <div className="small muted">#{id.toString()} · {KINDS[p.kind]} · {open ? "open" : "closed"}</div>
                <div>{p.description}</div>
                <div className="small">For {formatUnits(p.forVotes, 18)} · Against {formatUnits(p.againstVotes, 18)}</div>
                {open && (
                  <div className="row" style={{ marginTop: 6 }}>
                    <button className="ghost" disabled={busy} onClick={() => send("Vote for", { address: hooks, abi: hooksAbi, functionName: "vote", args: [id, true] })}>For</button>
                    <button className="ghost" disabled={busy} onClick={() => send("Vote against", { address: hooks, abi: hooksAbi, functionName: "vote", args: [id, false] })}>Against</button>
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </>
  );
}

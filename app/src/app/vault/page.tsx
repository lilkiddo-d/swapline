"use client";

import { useState } from "react";
import { useReadContracts } from "wagmi";
import { deployment, marketLabel, ZERO } from "@/lib/deployment";
import { erc20Abi, vaultAbi } from "@/lib/abis";
import { useConnected, useMarkets, useTx } from "@/lib/hooks";
import { pct, usd, parseUsd, date, daysLeft } from "@/lib/format";
import { PendingDeployment, RiskGate } from "@/components/common";

export default function FixedRateVaultPage() {
  const account = useConnected();
  const { send, status, busy } = useTx();
  const { data: markets } = useMarkets();
  const vaults = deployment.markets.map((m, i) => ({ m, i })).filter((x) => x.m.vault !== ZERO);
  const [sel, setSel] = useState(vaults[0]?.i ?? 0);
  const [amount, setAmount] = useState("1000");
  const m = deployment.markets[sel];

  const per = 7;
  const { data, refetch } = useReadContracts({
    contracts: vaults.flatMap(({ m: vm }) => [
      { address: vm.vault, abi: vaultAbi, functionName: "totalAssets" },
      { address: vm.vault, abi: vaultAbi, functionName: "balanceOf", args: [account ?? ZERO] },
      { address: vm.vault, abi: vaultAbi, functionName: "maxWithdraw", args: [account ?? ZERO] },
      { address: vm.vault, abi: vaultAbi, functionName: "swapSettled" },
      { address: vm.vault, abi: vaultAbi, functionName: "maxDeposit", args: [account ?? ZERO] },
      { address: deployment.stablecoin, abi: erc20Abi, functionName: "allowance", args: [account ?? ZERO, vm.vault] },
      { address: vm.vault, abi: vaultAbi, functionName: "totalSupply" },
    ] as const),
    allowFailure: true,
  });
  const at = (vi: number, k: number) => data?.[vi * per + k]?.result as unknown;
  const vi = vaults.findIndex((v) => v.i === sel);

  async function deposit() {
    if (!account || !m) return;
    const a = parseUsd(amount);
    const allowance = (at(vi, 5) as bigint | undefined) ?? 0n;
    if (allowance < a && !(await send("Approve USDG", { address: deployment.stablecoin, abi: erc20Abi, functionName: "approve", args: [m.vault, a] }))) return;
    await send("Deposit & lock rate", { address: m.vault, abi: vaultAbi, functionName: "deposit", args: [a, account] });
    refetch();
  }

  if (vaults.length === 0) return <PendingDeployment />;
  return (
    <>
      <h1>Fixed-rate vault</h1>
      <p className="sub">
        Earn a fixed rate on USDG until maturity. Your deposit goes into the floating source and the vault automatically
        swaps that floating income for a fixed rate. Withdraw after maturity; vault shares are transferable before.
      </p>
      <RiskGate>
        <div className="grid">
          {vaults.map(({ m: vm, i }, k) => {
            const settled = at(k, 3) as boolean | undefined;
            const shares = at(k, 1) as bigint | undefined;
            return (
              <div key={vm.vault} className="panel" style={{ outline: sel === i ? "2px solid var(--accent)" : undefined, cursor: "pointer" }} onClick={() => setSel(i)}>
                <h2>{marketLabel(vm)}</h2>
                <div className="muted small">Lock rate today (approx.)</div>
                <div className="kpi">{pct(markets[i]?.rate)}</div>
                <p className="muted small">
                  Matures {date(vm.maturity)} ({daysLeft(vm.maturity)} days) · TVL {usd(at(k, 0) as bigint | undefined, 0)} USDG
                  {settled ? " · settled" : ""}
                </p>
                {account && (shares ?? 0n) > 0n && (
                  <p className="small">You: {usd(((at(k, 0) as bigint) * (shares as bigint)) / ((at(k, 6) as bigint) || 1n))} USDG (est.)</p>
                )}
              </div>
            );
          })}
        </div>
        {m && (
          <div className="panel" style={{ marginTop: 16, maxWidth: 520 }}>
            <h2>{marketLabel(m)}</h2>
            <label>Deposit (USDG)</label>
            <input value={amount} onChange={(e) => setAmount(e.target.value)} />
            <p className="muted small">
              5% of a deposit is posted as swap margin; the rest earns the floating rate, which is swapped for fixed. The
              rate you lock is roughly the current fixed rate × 95% (minus a small fee). Deposits close 1 day before maturity.
            </p>
            <div className="row">
              <button disabled={!account || busy || (at(vi, 4) as bigint | undefined) === 0n} onClick={deposit}>Deposit & lock rate</button>
              {Date.now() / 1000 >= m.maturity && !(at(vi, 3) as boolean) && (
                <button className="ghost" disabled={busy} onClick={async () => { await send("Settle vault", { address: m.vault, abi: vaultAbi, functionName: "settleVault" }); refetch(); }}>Settle vault</button>
              )}
              {((at(vi, 2) as bigint | undefined) ?? 0n) > 0n && (
                <button className="ghost" disabled={busy} onClick={async () => { await send("Withdraw", { address: m.vault, abi: vaultAbi, functionName: "redeem", args: [at(vi, 1) as bigint, account!, account!] }); refetch(); }}>
                  Withdraw {usd(at(vi, 2) as bigint)} USDG
                </button>
              )}
            </div>
            <div className="status">{status}</div>
          </div>
        )}
      </RiskGate>
    </>
  );
}

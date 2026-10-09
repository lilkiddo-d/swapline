"use client";

import { useCallback, useEffect, useState } from "react";
import { useAccount, usePublicClient, useReadContracts, useWriteContract } from "wagmi";
import type { Abi, Address } from "viem";
import { deployment, type MarketDeployment } from "./deployment";
import { marketAbi, oracleAbi, vammAbi } from "./abis";

export interface MarketData {
  m: MarketDeployment;
  rate?: bigint; // implied fixed rate (vAMM)
  liquidity?: bigint;
  floating?: bigint; // trailing 7d floating rate of the source, from on-chain index growth
  healthy?: boolean;
  impaired?: boolean;
}

const WEEK = 7n * 24n * 3600n;

/** Live rates for every market: implied fixed (vAMM) and the source's floating rate (oracle). */
export function useMarkets(): { data: MarketData[]; isLoading: boolean } {
  const contracts = deployment.markets.flatMap((m) => {
    const oracle = deployment.sources.find((s) => s.key === m.source)!.oracle;
    return [
      { address: m.market, abi: marketAbi, functionName: "currentRate" },
      { address: m.vamm, abi: vammAbi, functionName: "liquidity" },
      { address: oracle, abi: oracleAbi, functionName: "currentFloatingRate", args: [WEEK] },
      { address: oracle, abi: oracleAbi, functionName: "isHealthy" },
      { address: oracle, abi: oracleAbi, functionName: "impaired" },
    ] as const;
  });
  const { data, isLoading } = useReadContracts({ contracts, allowFailure: true });
  const out = deployment.markets.map((m, i) => {
    const r = (k: number) => data?.[i * 5 + k]?.result as unknown;
    const floating = r(2) as bigint | undefined;
    return {
      m,
      rate: r(0) as bigint | undefined,
      liquidity: r(1) as bigint | undefined,
      floating: floating !== undefined && floating < 0n ? 0n : floating,
      healthy: r(3) as boolean | undefined,
      impaired: r(4) as boolean | undefined,
    };
  });
  return { data: out, isLoading };
}

/** Send a transaction and wait for its receipt, with a human-readable status line. */
export function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const [status, setStatus] = useState<string>("");
  const [busy, setBusy] = useState(false);

  const send = useCallback(
    async (label: string, req: { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] }) => {
      setBusy(true);
      setStatus(`${label}: confirm in your wallet…`);
      try {
        const hash = await writeContractAsync(req as never);
        setStatus(`${label}: pending ${hash.slice(0, 10)}…`);
        const receipt = await client!.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") throw new Error("transaction reverted");
        setStatus(`${label}: confirmed ✓`);
        return true;
      } catch (e) {
        const msg = (e as { shortMessage?: string; message?: string }).shortMessage ?? (e as Error).message;
        setStatus(`${label}: ${msg}`);
        return false;
      } finally {
        setBusy(false);
      }
    },
    [writeContractAsync, client],
  );
  return { send, status, busy };
}

const ACK_KEY = "swapline.riskAck.v1";

/** Per-browser acknowledgement of the risk disclosure (convenience only; never security-relevant). */
export function useRiskAck(): [boolean, (v: boolean) => void] {
  const [ack, setAck] = useState(false);
  useEffect(() => {
    try {
      setAck(window.localStorage.getItem(ACK_KEY) === "1");
    } catch {
      /* storage unavailable: ask every visit */
    }
  }, []);
  const update = (v: boolean) => {
    setAck(v);
    try {
      window.localStorage.setItem(ACK_KEY, v ? "1" : "0");
    } catch {
      /* ignore */
    }
  };
  return [ack, update];
}

export function useConnected(): Address | undefined {
  const { address, isConnected } = useAccount();
  return isConnected ? address : undefined;
}

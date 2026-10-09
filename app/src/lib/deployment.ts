import type { Address } from "viem";
import fork from "@/config/deployments.31337.json";
import mainnet from "@/config/deployments.4663.json";
import { robinhood, robinhoodFork } from "@config/chains";

export interface SourceDeployment {
  key: string;
  description: string;
  yieldToken: Address;
  rateSource: Address;
  oracle: Address;
}
export interface MarketDeployment {
  source: string;
  maturity: number;
  maturityDays: number;
  market: Address;
  vamm: Address;
  vault: Address;
}
export interface Deployment {
  chainId: number;
  pending?: boolean;
  stablecoin: Address;
  marginEngine: Address;
  lpPositions: Address;
  marketFactory: Address;
  liquidator: Address;
  feeCollector: Address;
  projectTokenHooks: Address;
  complianceRegistry: Address;
  timelock: Address;
  sources: SourceDeployment[];
  markets: MarketDeployment[];
}

export const network = (process.env.NEXT_PUBLIC_CHAIN ?? "fork") === "mainnet" ? "mainnet" : "fork";
export const chain = network === "mainnet" ? robinhood : robinhoodFork;
export const rpcUrl = process.env.NEXT_PUBLIC_RPC_URL || chain.rpcUrls.default.http[0];
export const deployment = (network === "mainnet" ? mainnet : fork) as unknown as Deployment;
export const ZERO: Address = "0x0000000000000000000000000000000000000000";

export const projectToken = (process.env.NEXT_PUBLIC_PROJECT_TOKEN || "") as Address | "";
export const tokenFeaturesEnabled = /^0x[0-9a-fA-F]{40}$/.test(projectToken);

export function sourceOf(m: MarketDeployment): SourceDeployment | undefined {
  return deployment.sources.find((s) => s.key === m.source);
}

export function marketLabel(m: MarketDeployment): string {
  return `${m.source} · ${m.maturityDays}D`;
}

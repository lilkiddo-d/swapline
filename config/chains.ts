/**
 * Robinhood Chain configuration for Swapline (frontend, keeper and docs).
 * Canonical data lives in ./robinhood.json (also read by contracts/script/Deploy.s.sol). Every address was taken
 * from the linked official source AND verified on-chain on 2026-10-09 — never edit without re-verifying.
 *
 * Sources
 *  - Network:            https://docs.robinhood.com/chain/connecting
 *  - Deploy & verify:    https://docs.robinhood.com/chain/deploy-smart-contracts
 *  - Token contracts:    https://docs.robinhood.com/chain/contracts           (USDG, WETH)
 *  - Protocol contracts: https://docs.robinhood.com/chain/protocol-contracts
 *  - Oracles:            https://docs.robinhood.com/chain/oracles-and-price-feeds -> Chainlink (USDG/USD)
 *  - Morpho:             https://docs.morpho.org/get-started/resources/addresses/
 *  - Steakhouse USDG:    https://app.morpho.org/robinhood-chain/vault/0xBeEff033F34C046626B8D0A041844C5d1A5409dd/steakhouse-usdg
 *  - Spark spUSDG:       https://docs.spark.finance/dev/savings/spark-vaults-v2
 *  - Maple syrupUSDG:    https://github.com/maple-labs/maple-docs/pull/157 (crosschain addresses, Robinhood tab)
 *  - Etherscan v2:       https://api.etherscan.io/v2/chainlist (chainid 4663 -> robin.etherscan.io)
 *  - Multicall3:         canonical deterministic address 0xcA11bde05977b3631167028862bE2a173976CA11, verified on-chain
 *                        2026-10-09 (code present, getChainId() == 4663)
 */
import { defineChain, type Address } from "viem";
import data from "./robinhood.json";

export const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [data.rpcUrl] } },
  blockExplorers: {
    default: { name: "Etherscan", url: "https://robin.etherscan.io" },
    blockscout: { name: "Blockscout", url: data.explorer },
  },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});

/** Local anvil fork of mainnet (scripts/fork/start-fork.ps1). */
export const robinhoodFork = defineChain({
  id: 31337,
  name: "Robinhood Chain (local fork)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:18546"] } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } }, // inherited from mainnet state
  testnet: true,
});

export const addresses = {
  USDG: data.tokens.USDG.address as Address,
  WETH: data.tokens.WETH.address as Address,
  USDG_USD_FEED: data.oracles.USDG_USD.address as Address,
  SYRUPUSDG_USDG_FEED: data.oracles.SYRUPUSDG_USDG_EXCHANGE_RATE.address as Address,
  MORPHO_BLUE: data.lending.MORPHO_BLUE.address as Address,
  MORPHO_ADAPTIVE_CURVE_IRM: data.lending.MORPHO_ADAPTIVE_CURVE_IRM.address as Address,
} as const;

export interface RateSourceInfo {
  key: string;
  kind: "erc4626" | "spark" | "chainlink";
  category: string;
  description: string;
  target: Address;
  yieldToken: Address;
  source: string;
}

export const rateSources: RateSourceInfo[] = data.rateSources.map((s) => ({
  key: s.key,
  kind: s.kind as RateSourceInfo["kind"],
  category: s.category,
  description: s.description,
  target: s.target as Address,
  yieldToken: s.yieldToken as Address,
  source: s.source,
}));

/** Things that do not exist on Robinhood Chain yet, and how Swapline handles them. */
export const gaps: string[] = data.gaps;

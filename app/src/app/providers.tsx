"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { RainbowKitProvider, connectorsForWallets, darkTheme } from "@rainbow-me/rainbowkit";
import { injectedWallet, metaMaskWallet, rabbyWallet, walletConnectWallet, coinbaseWallet } from "@rainbow-me/rainbowkit/wallets";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider, createConfig, http } from "wagmi";
import { useState, type ReactNode } from "react";
import { chain, rpcUrl } from "@/lib/deployment";

const wcProjectId = process.env.NEXT_PUBLIC_WC_PROJECT_ID || "";

// WalletConnect-based wallets need a project id; injected wallets (MetaMask, Rabby, browser) work without one.
const connectors = connectorsForWallets(
  [
    {
      groupName: "Wallets",
      wallets: wcProjectId
        ? [injectedWallet, metaMaskWallet, rabbyWallet, coinbaseWallet, walletConnectWallet]
        : [injectedWallet, rabbyWallet],
    },
  ],
  { appName: "Swapline", projectId: wcProjectId || "swapline-no-walletconnect" },
);

export const wagmiConfig = createConfig({
  chains: [chain],
  connectors,
  // `chain` is either mainnet (4663) or the local fork (31337); only the selected one is used
  transports: { 4663: http(rpcUrl), 31337: http(rpcUrl) },
  ssr: true,
});

export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(() => new QueryClient({ defaultOptions: { queries: { refetchInterval: 15_000 } } }));
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider theme={darkTheme({ accentColor: "#5b8cff", borderRadius: "medium" })} modalSize="compact">
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}

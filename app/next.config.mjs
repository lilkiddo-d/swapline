/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // config/chains.ts and config/robinhood.json live at the repo root (shared with contracts + keeper)
  experimental: { externalDir: true },
  webpack: (config) => {
    // optional deps pulled in by WalletConnect / MetaMask SDK that are not used in the browser bundle
    config.externals.push("pino-pretty", "lokijs", "encoding");
    config.resolve.fallback = { ...config.resolve.fallback, "@react-native-async-storage/async-storage": false };
    // optional x402 payment modules referenced by the Coinbase/Base Account SDK (not used by Swapline)
    config.resolve.alias = {
      ...config.resolve.alias,
      "@x402/evm": false,
      "@x402/evm/exact/client": false,
      "@x402/svm": false,
      "@x402/svm/exact/client": false,
      "@x402/core": false,
      "@x402/fetch": false,
    };
    return config;
  },
};
export default nextConfig;

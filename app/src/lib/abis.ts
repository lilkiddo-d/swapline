import { parseAbi } from "viem";

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
]);

export const oracleAbi = parseAbi([
  "function currentIndex() view returns (uint256)",
  "function currentFloatingRate(uint256 lookback) view returns (int256)",
  "function isHealthy() view returns (bool)",
  "function impaired() view returns (bool)",
  "function observationCount() view returns (uint256)",
]);

export const marketAbi = parseAbi([
  "function currentRate() view returns (uint256)",
  "function maturity() view returns (uint256)",
  "function tau() view returns (uint256)",
  "function settled(address) view returns (bool)",
  "function settlementIndex() view returns (uint256)",
  "function grossVarSharesX18() view returns (uint256)",
  "function rawBalances(address) view returns (int256 varSharesX18, int256 fixedCashX18)",
  "function accountState(address) view returns ((int256 varSharesX18, int256 fixedCashX18, uint256 lpUnfilledNotional, uint256 lpFeesOwed, bool hasPosition))",
  "function params() view returns (uint256 feeRate, uint256 protocolFeeBps, uint256 maxOpenInterestBps, uint256 tradeCutoff)",
  "function trade(int256 notional, uint256 rateLimit, uint256 deadline) returns (int256 filled, uint256 fee)",
  "function mint(int24 lower, int24 upper, uint128 liquidityAmount)",
  "function burn(int24 lower, int24 upper, uint128 liquidityAmount)",
  "function collect(int24 lower, int24 upper)",
  "function settle(address account) returns (int256)",
]);

export const vammAbi = parseAbi([
  "function liquidity() view returns (uint128)",
  "function rate() view returns (uint256)",
  "function tick() view returns (int24)",
]);

export const marginEngineAbi = parseAbi([
  "function marginOf(address market, address account) view returns (uint256)",
  "function health(address market, address account) view returns ((int256 equity, uint256 initialRequirement, uint256 maintenanceRequirement, uint256 exposure))",
  "function initialHealth(address market, address account) view returns ((int256 equity, uint256 initialRequirement, uint256 maintenanceRequirement, uint256 exposure))",
  "function isLiquidatable(address market, address account) view returns (bool)",
  "function insuranceFund() view returns (uint256)",
  "function paused() view returns (bool)",
  "function deposit(address market, address account, uint256 amount)",
  "function withdraw(address market, uint256 amount, address to)",
]);

export const lpPositionsAbi = parseAbi([
  "function positionsOf(address market, address owner) view returns ((int24 lower, int24 upper, uint128 liquidity, uint256 feeGrowthInsideLast, int256 varGrowthInsideLast, int256 fixedGrowthInsideLast)[])",
]);

export const vaultAbi = parseAbi([
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function convertToAssets(uint256) view returns (uint256)",
  "function maxWithdraw(address) view returns (uint256)",
  "function maxRedeem(address) view returns (uint256)",
  "function maxDeposit(address) view returns (uint256)",
  "function swapSettled() view returns (bool)",
  "function deposit(uint256 assets, address receiver) returns (uint256)",
  "function depositWithMinRate(uint256 assets, address receiver, uint256 minRate) returns (uint256)",
  "function redeem(uint256 shares, address receiver, address owner) returns (uint256)",
  "function settleVault()",
]);

export const hooksAbi = parseAbi([
  "function tokenSet() view returns (bool)",
  "function totalStaked() view returns (uint256)",
  "function stakeOf(address) view returns (uint256)",
  "function earned(address) view returns (uint256)",
  "function pendingUnstake(address) view returns (uint256 amount, uint256 availableAt)",
  "function proposalCount() view returns (uint256)",
  "function proposal(uint256 id) view returns ((uint8 kind, address proposer, uint64 start, uint64 end, uint256 forVotes, uint256 againstVotes, uint256 totalStakedAtStart, bytes32 payloadHash, string description))",
  "function passed(uint256 id) view returns (bool)",
  "function hasVoted(uint256 id, address voter) view returns (bool)",
  "function stake(uint256 amount)",
  "function requestUnstake(uint256 amount)",
  "function withdraw()",
  "function claim() returns (uint256)",
  "function vote(uint256 id, bool support)",
  "function propose(uint8 kind, bytes32 payloadHash, string description) returns (uint256)",
]);

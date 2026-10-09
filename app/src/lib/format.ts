export const WAD = 10n ** 18n;
export const USD = 10n ** 6n;

/** 18-decimal rate -> "4.25%" */
export function pct(rate: bigint | undefined, digits = 2): string {
  if (rate === undefined) return "—";
  return `${(Number(rate) / 1e16).toFixed(digits)}%`;
}

/** 6-decimal token amount -> "12,345.67" */
export function usd(amount: bigint | undefined, digits = 2): string {
  if (amount === undefined) return "—";
  const n = Number(amount) / 1e6;
  return n.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function parseUsd(input: string): bigint {
  const clean = input.replace(/,/g, "").trim();
  if (!/^\d*\.?\d*$/.test(clean) || clean === "" || clean === ".") return 0n;
  const [w, f = ""] = clean.split(".");
  return BigInt(w || "0") * USD + BigInt((f + "000000").slice(0, 6));
}

export function parsePct(input: string): bigint {
  const n = Number(input);
  if (!Number.isFinite(n)) return 0n;
  return BigInt(Math.round(n * 1e4)) * 10n ** 12n; // percent with 4 decimals -> WAD
}

export function date(ts: number | bigint): string {
  return new Date(Number(ts) * 1000).toISOString().slice(0, 10);
}

export function daysLeft(ts: number | bigint): number {
  return Math.max(0, Math.round((Number(ts) * 1000 - Date.now()) / 86_400_000));
}

export function short(a: string): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

import { NextResponse, type NextRequest } from "next/server";

/**
 * Optional geoblock. NEXT_PUBLIC_BLOCKED_COUNTRIES is a comma-separated list of ISO-3166 alpha-2 codes; the
 * visitor's country comes from the hosting edge (x-vercel-ip-country on Vercel). Empty list = no blocking.
 * This is a front-end courtesy control only; the protocol itself is permissionless unless ComplianceRegistry is on.
 */
const blocked = (process.env.NEXT_PUBLIC_BLOCKED_COUNTRIES ?? "")
  .split(",")
  .map((c) => c.trim().toUpperCase())
  .filter(Boolean);

export function middleware(req: NextRequest) {
  if (blocked.length === 0) return NextResponse.next();
  const country = (req.headers.get("x-vercel-ip-country") ?? "").toUpperCase();
  if (country && blocked.includes(country) && req.nextUrl.pathname !== "/blocked") {
    return NextResponse.redirect(new URL("/blocked", req.url));
  }
  return NextResponse.next();
}

export const config = { matcher: ["/((?!_next|favicon.ico|blocked).*)"] };

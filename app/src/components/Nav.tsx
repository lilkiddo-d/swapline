"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { tokenFeaturesEnabled, network } from "@/lib/deployment";

const links = [
  { href: "/", label: "Rates" },
  { href: "/trade", label: "Trade" },
  { href: "/positions", label: "Positions" },
  { href: "/lp", label: "Provide liquidity" },
  { href: "/vault", label: "Fixed-rate vault" },
  ...(tokenFeaturesEnabled ? [{ href: "/stake", label: "Stake" }] : []),
  { href: "/risk", label: "Risks" },
];

export function Nav() {
  const path = usePathname();
  return (
    <header className="top">
      <div className="wrap">
        <Link href="/" className="brand">
          Swap<span>line</span>
        </Link>
        <nav className="links">
          {links.map((l) => (
            <Link key={l.href} href={l.href} className={path === l.href ? "active" : ""}>
              {l.label}
            </Link>
          ))}
        </nav>
        {network === "fork" && <span className="pill warn">local fork</span>}
        <ConnectButton chainStatus="icon" showBalance={false} accountStatus="address" />
      </div>
    </header>
  );
}

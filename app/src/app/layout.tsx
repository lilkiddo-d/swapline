import type { Metadata } from "next";
import "./globals.css";
import { Providers } from "./providers";
import { Nav } from "@/components/Nav";

export const metadata: Metadata = {
  title: "Swapline — fixed vs floating on RWA yields",
  description: "Interest-rate swaps on tokenized money-market and lending yields.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Nav />
          <main className="wrap">{children}</main>
          <footer>
            <div className="wrap">
              Swapline is experimental, unaudited software. Swaps can lose more than expected; read the{" "}
              <a href="/risk">risk disclosure</a>. Swapline is independent and not affiliated with any chain operator
              or rate-source issuer.
            </div>
          </footer>
        </Providers>
      </body>
    </html>
  );
}

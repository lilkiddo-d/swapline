"use client";

import { useRiskAck } from "@/lib/hooks";
import { gaps } from "@config/chains";

export default function Risk() {
  const [ack, setAck] = useRiskAck();
  return (
    <>
      <h1>Risk disclosure</h1>
      <p className="sub">Read this before trading, providing liquidity or depositing. Swapline is experimental, unaudited software.</p>
      <div className="panel" style={{ lineHeight: 1.65 }}>
        <h2>Swaps are leveraged</h2>
        <p>
          A swap exchanges a fixed rate for a floating rate on a notional amount. You post only a fraction of the notional
          as margin, so a move in rates can cost more than your margin. Positions below maintenance margin can be
          liquidated by anyone; the liquidator is paid from your margin. Losses beyond your margin become bad debt that
          is covered by the insurance fund first.
        </p>
        <h2>Floating rates come from third-party yield sources</h2>
        <p>
          The floating leg follows the exchange rate of external products (a Morpho lending vault curated by Steakhouse,
          the Spark savings vault, and Maple&apos;s syrupUSDG exchange-rate feed). If a source loses value — bad debt, a
          default, an issuer pause or a hack — the realised floating rate can be negative. Receive-floating positions then
          pay, and new trading on that source is halted. Swapline does not control or guarantee these sources.
        </p>
        <h2>Fixed-rate vault</h2>
        <p>
          The vault holds the floating source&apos;s shares directly, so a loss at the source reduces what you get back.
          Assets can only be withdrawn after maturity; before that you can only transfer vault shares. The vault&apos;s
          swap can in principle be liquidated in extreme rate moves.
        </p>
        <h2>Liquidity and pricing</h2>
        <p>
          Fixed rates are quoted by an automated market maker with liquidity from LPs. If liquidity runs out you may not be
          able to open or close before maturity (settlement at maturity always works). LPs take the other side of trades
          and can lose money.
        </p>
        <h2>Smart-contract, oracle and stablecoin risk</h2>
        <p>
          Contracts may contain bugs. Margin is USDG; a depeg blocks new positions but does not change USDG-denominated
          PnL. Oracle data can be stale or wrong. Admin actions are subject to a 48-hour timelock; a guardian can pause
          trading at any time (deposits and settlement stay open).
        </p>
        <h2>Known gaps on this chain</h2>
        <ul>{gaps.map((g) => <li key={g}>{g}</li>)}</ul>
        <h2>Eligibility</h2>
        <p>
          You are responsible for complying with the laws of your jurisdiction. Access may be restricted in some regions.
          Nothing here is investment advice.
        </p>
        <div className="row" style={{ marginTop: 16 }}>
          {ack ? (
            <>
              <span className="pill ok">Acknowledged</span>
              <button className="ghost" onClick={() => setAck(false)}>Withdraw acknowledgement</button>
            </>
          ) : (
            <button onClick={() => setAck(true)}>I have read and understood these risks</button>
          )}
        </div>
      </div>
    </>
  );
}

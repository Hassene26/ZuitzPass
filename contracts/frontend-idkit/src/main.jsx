import React, { useState } from "react";
import { createRoot } from "react-dom/client";
import { IDKitRequestWidget, orbLegacy, setDebug } from "@worldcoin/idkit";
import { AbiCoder, toBeHex } from "ethers";

// Verbose IDKit logging -> the real reason behind the generic "Something went wrong" modal.
setDebug(true);

const coder = AbiCoder.defaultAbiCoder();

// orbLegacy (World ID legacy proof) returns proof as an 8-element array of hex strings, OR an
// ABI-encoded uint256[8] blob depending on version. Normalize to 8 hex strings for the fixture.
function decodeProof(proof) {
  if (Array.isArray(proof)) return proof.map((x) => toBeHex(BigInt(x)));
  const [arr] = coder.decode(["uint256[8]"], proof);
  return arr.map((x) => toBeHex(x));
}

const box = { background: "#191d31", border: "1px solid #2c3355", borderRadius: 14, padding: 18, marginBottom: 16 };
const input = { width: "100%", background: "#0b0e1a", border: "1px solid #2c3355", borderRadius: 9, color: "#e8ebff", padding: "9px 11px", fontFamily: "ui-monospace,Menlo,monospace", fontSize: 12, boxSizing: "border-box" };
const label = { display: "block", color: "#9aa2c8", fontSize: 12, margin: "10px 0 4px" };
const btn = { background: "#6c8cff", color: "#fff", border: 0, borderRadius: 10, padding: "10px 16px", fontWeight: 600, cursor: "pointer" };

function App() {
  const env = import.meta.env;
  const [appId, setAppId] = useState(env.VITE_APP_ID || "");
  const [action, setAction] = useState(env.VITE_ACTION || "zuitzpass-access");
  const [signal, setSignal] = useState(env.VITE_SIGNAL || "0x000000000000000000000000000000000000bEEF");

  const [rpContext, setRpContext] = useState(null);
  const [open, setOpen] = useState(false);
  const [fixture, setFixture] = useState("");
  const [raw, setRaw] = useState("");
  const [status, setStatus] = useState("");

  const prepareAndOpen = async () => {
    try {
      setStatus("Requesting RP signature from backend…");
      const r = await fetch("/api/rp-signature", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ action }),
      });
      const s = await r.json();
      if (!r.ok) throw new Error(s.error || "rp-signature failed");
      // Map idkit-server's RpSignature -> the widget's RpContext (snake_case).
      setRpContext({
        rp_id: s.rp_id,
        nonce: s.nonce,
        created_at: s.createdAt,
        expires_at: s.expiresAt,
        signature: s.sig,
      });
      setStatus("RP signature ready — opening widget. Scan with simulator.worldcoin.org.");
      setOpen(true);
    } catch (e) {
      setStatus("Error: " + String(e?.message || e));
    }
  };

  const onSuccess = (result) => {
    setRaw(JSON.stringify(result, null, 2));
    try {
      // World ID 3.0 legacy nests the proof under responses[0]; fall back to flat for safety.
      const r = (result.responses && result.responses[0]) || result;
      const root = r.merkle_root ?? r.root;
      const nullifierHash = r.nullifier ?? r.nullifier_hash;
      setFixture(
        JSON.stringify(
          {
            appId,
            action,
            signal,
            root,
            nullifierHash,
            proof: decodeProof(r.proof),
            signal_hash: r.signal_hash, // reference: gate must recompute this from `signal`
          },
          null,
          2
        )
      );
      setStatus("Proof captured ✓");
    } catch (e) {
      setStatus("Got a proof but couldn't shape the fixture: " + String(e?.message || e) + " — see raw result below.");
    }
  };

  return (
    <div style={{ maxWidth: 760, margin: "0 auto", padding: 28, color: "#e8ebff", fontFamily: "-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif" }}>
      <h1 style={{ fontSize: 20, margin: "0 0 2px" }}>World ID — proof capture (IDKit v4, orbLegacy)</h1>
      <p style={{ color: "#9aa2c8", margin: "0 0 20px" }}>
        Staging + legacy Orb proof for the classic on-chain gate. Backend signs the RP request;
        the simulator plays the identity. Fills <code>../test/fixtures/worldid_proof.json</code>.
      </p>

      <div style={box}>
        <label style={label}>app_id (from Developer Portal — VITE_APP_ID)</label>
        <input style={input} value={appId} onChange={(e) => setAppId(e.target.value)} />
        <label style={label}>action (Incognito Action)</label>
        <input style={input} value={action} onChange={(e) => setAction(e.target.value)} />
        <label style={label}>signal — full wallet address you'll call gate.verify() from</label>
        <input style={input} value={signal} onChange={(e) => setSignal(e.target.value)} />

        <div style={{ marginTop: 14 }}>
          <button style={btn} onClick={prepareAndOpen}>Prepare RP signature &amp; open widget</button>
        </div>
        {status && <p style={{ color: "#9aa2c8", fontSize: 12, marginTop: 10 }}>{status}</p>}

        {rpContext && (
          <IDKitRequestWidget
            open={open}
            onOpenChange={setOpen}
            app_id={appId}
            action={action}
            environment="staging"
            allow_legacy_proofs={true}
            preset={orbLegacy({ signal })}
            rp_context={rpContext}
            handleVerify={async () => {}} /* on-chain gate is our verifier; no backend check here */
            onSuccess={onSuccess}
            onError={(e) => {
              console.error("[IDKit onError]", e);
              setStatus("Widget error: " + JSON.stringify(e));
            }}
          />
        )}
      </div>

      <div style={box}>
        <label style={label}>Fixture JSON — paste into test/fixtures/worldid_proof.json</label>
        <textarea style={{ ...input, minHeight: 150 }} readOnly value={fixture} />
        {fixture && (
          <button style={{ ...btn, background: "#212745", border: "1px solid #2c3355", marginTop: 12 }}
            onClick={() => navigator.clipboard.writeText(fixture)}>Copy JSON</button>
        )}
      </div>

      {raw && (
        <div style={box}>
          <label style={label}>Raw IDKit result (for debugging field names)</label>
          <textarea style={{ ...input, minHeight: 120 }} readOnly value={raw} />
        </div>
      )}
    </div>
  );
}

createRoot(document.getElementById("root")).render(<App />);

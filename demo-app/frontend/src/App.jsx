import React, { useEffect, useState } from "react";
import { IDKitRequestWidget, orbLegacy } from "@worldcoin/idkit";
import { api } from "./api.js";
import { connectWallet, address, sendTx } from "./wallet.js";

const c = {
  page: { minHeight: "100vh", background: "#0f1220", color: "#e8ebff", fontFamily: "-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif", padding: 28 },
  wrap: { maxWidth: 820, margin: "0 auto" },
  card: { background: "#191d31", border: "1px solid #2c3355", borderRadius: 14, padding: 18, marginBottom: 16 },
  btn: { background: "#6c8cff", color: "#fff", border: 0, borderRadius: 10, padding: "9px 14px", fontWeight: 600, cursor: "pointer", fontSize: 13, marginRight: 8 },
  ghost: { background: "#212745", border: "1px solid #2c3355", color: "#e8ebff" },
  disabled: { opacity: 0.4, cursor: "not-allowed" },
  input: { background: "#0b0e1a", border: "1px solid #2c3355", borderRadius: 9, color: "#e8ebff", padding: "9px 11px", fontSize: 13, marginRight: 8 },
  mono: { fontFamily: "ui-monospace,Menlo,monospace", fontSize: 12, color: "#9aa2c8" },
  step: { padding: "8px 0", borderBottom: "1px dashed #2c3355" },
  ok: { color: "#35d07f" }, bad: { color: "#ff6b6b" }, muted: { color: "#9aa2c8" },
  tag: { display: "inline-block", background: "#2a315a", borderRadius: 999, padding: "2px 10px", fontSize: 12, marginLeft: 8 },
  logbox: { background: "#0b0e1a", border: "1px solid #2c3355", borderRadius: 10, padding: 12, height: 140, overflow: "auto", fontFamily: "ui-monospace,monospace", fontSize: 12 },
};
const short = (h) => (h && h.length > 16 ? `${h.slice(0, 10)}…${h.slice(-6)}` : h);

export default function App() {
  const [wallet, setWallet] = useState(null);
  const [tab, setTab] = useState("alice");
  const [log, setLog] = useState([]);
  const addLog = (m, ok) => setLog((l) => [...l.slice(-40), { m, ok, t: new Date().toLocaleTimeString() }]);

  const connect = async () => {
    try { setWallet(await connectWallet()); addLog("wallet connected " + address(), true); }
    catch (e) { addLog(e.message, false); }
  };

  return (
    <div style={c.page}>
      <div style={c.wrap}>
        <h1 style={{ margin: "0 0 2px" }}>ZuitzPass — unlinkable access demo</h1>
        <p style={c.muted}>Alice proves she's a human via World ID, then joins Bob's event — the event only ever sees a per-app nullifier, never Alice's identity.</p>

        <div style={c.card}>
          {wallet ? <span style={c.ok}>● wallet {short(wallet)}</span> : <button style={c.btn} onClick={connect}>Connect MetaMask</button>}
          <span style={c.muted}> · connect the deployer account (owns statements + is the tree writer)</span>
          <div style={{ marginTop: 12 }}>
            <button style={{ ...c.btn, ...(tab === "alice" ? {} : c.ghost) }} onClick={() => setTab("alice")}>Alice (user)</button>
            <button style={{ ...c.btn, ...(tab === "bob" ? {} : c.ghost) }} onClick={() => setTab("bob")}>Bob (organizer)</button>
          </div>
        </div>

        {/* Both stay mounted so Alice's progress persists when switching tabs. */}
        <div style={{ display: tab === "alice" ? "block" : "none" }}><Alice wallet={wallet} addLog={addLog} /></div>
        <div style={{ display: tab === "bob" ? "block" : "none" }}><Bob wallet={wallet} addLog={addLog} /></div>

        <div style={c.card}>
          <div style={c.muted}>Log</div>
          <div style={c.logbox}>
            {log.map((e, i) => (
              <div key={i} style={e.ok === false ? c.bad : e.ok ? c.ok : c.muted}>{e.t} {e.m}</div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function Alice({ wallet, addLog }) {
  const [state, setState] = useState(null); // { idc, credential, hasClaim }
  const [verified, setVerified] = useState(false);
  const [inserted, setInserted] = useState(false);
  const [redeemed, setRedeemed] = useState(false);
  const [rpContext, setRpContext] = useState(null);
  const [appId, setAppId] = useState(null);
  const [open, setOpen] = useState(false);
  const [events, setEvents] = useState([]);
  const [busy, setBusy] = useState("");
  const [phase, setPhase] = useState(""); // sub-progress of the merged humanity step

  const refreshEvents = async () => { try { setEvents((await api.events()).events); } catch {} };
  useEffect(() => { refreshEvents(); }, []);

  const register = async () => {
    try { setBusy("register"); const s = await api.registerAlice(); setState(s); setVerified(false); setInserted(false); setRedeemed(false); addLog("Alice registered — idc " + short(s.idc), true); }
    catch (e) { addLog(e.message, false); } finally { setBusy(""); }
  };

  const openWorldId = async () => {
    try {
      setBusy("worldid");
      const s = await api.rpSignature("zuitzpass-access");
      setAppId(s.app_id);
      setRpContext({ rp_id: s.rp_id, nonce: s.nonce, created_at: s.createdAt, expires_at: s.expiresAt, signature: s.sig });
      setOpen(true);
      addLog("World ID request ready — scan with the simulator", true);
    } catch (e) { addLog(e.message, false); } finally { setBusy(""); }
  };

  // World ID success -> deposit credential (Part A) -> redeem (Circuit B), all chained.
  const claimHumanity = async () => {
    setVerified(true);
    addLog("World ID verified — you're a unique human", true);
    try {
      setBusy("claim");
      setPhase("Depositing your credential… (approve in MetaMask)");
      const ins = await api.insertCredentialTx();
      await sendTx(ins.tx);
      setInserted(true);
      addLog("credential deposited into VerifiedHumansTree (Part A)", true);

      setPhase("Proving Circuit B & minting your claim… (approve in MetaMask)");
      const red = await api.redeem();
      await sendTx(red.tx);
      setRedeemed(true);
      addLog("humanity claim minted to your hidden identity (Circuit B)", true);
      setPhase("");
    } catch (e) {
      addLog(e.message, false);
      setPhase("failed — " + e.message);
    } finally {
      setBusy("");
    }
  };

  const join = async (ev) => {
    try {
      setBusy("join" + ev.statementId);
      addLog(`proving Circuit A for "${ev.name}"…`, null);
      const { tx, nullifier } = await api.join(ev.statementId, address());
      await sendTx(tx);
      addLog(`joined "${ev.name}" — the event saw only nullifier ${short(nullifier)}`, true);
      refreshEvents();
    } catch (e) { addLog(e.message, false); } finally { setBusy(""); }
  };

  const Step = ({ n, title, done, children }) => (
    <div style={c.step}>
      <b>{n}. {title}</b> {done && <span style={c.ok}>✓</span>}
      <div style={{ marginTop: 6 }}>{children}</div>
    </div>
  );

  return (
    <div style={c.card}>
      <h2 style={{ marginTop: 0 }}>Alice</h2>

      <Step n={1} title="Create your identity" done={!!state}>
        <button style={{ ...c.btn, ...(busy ? c.disabled : {}) }} disabled={!!busy} onClick={register}>Register</button>
        {state && <span style={c.mono}> idc {short(state.idc)}</span>}
      </Step>

      <Step n={2} title="Prove you're a human & claim it" done={redeemed}>
        <button style={{ ...c.btn, ...(!state || !wallet || busy ? c.disabled : {}) }} disabled={!state || !wallet || !!busy} onClick={openWorldId}>Connect World ID</button>
        <div style={{ marginTop: 6 }}>
          <span style={verified ? c.ok : c.muted}>World ID {verified ? "✓" : "—"}</span>
          <span style={{ ...(inserted ? c.ok : c.muted), marginLeft: 14 }}>credential {inserted ? "✓" : "—"}</span>
          <span style={{ ...(redeemed ? c.ok : c.muted), marginLeft: 14 }}>claim {redeemed ? "✓" : "—"}</span>
        </div>
        {phase && <div style={{ ...c.muted, marginTop: 6 }}>{phase}</div>}
        {rpContext && appId && (
          <IDKitRequestWidget
            open={open} onOpenChange={setOpen}
            app_id={appId} action="zuitzpass-access" environment="staging"
            allow_legacy_proofs={true} preset={orbLegacy({ signal: address() || "0x0" })}
            rp_context={rpContext}
            handleVerify={async () => {}}
            onSuccess={claimHumanity}
            onError={(e) => addLog("World ID error: " + JSON.stringify(e), false)}
          />
        )}
      </Step>

      <Step n={3} title="Join an event (Circuit A eligibility)" done={false}>
        {events.length === 0 && <span style={c.muted}>no events yet — switch to Bob and create one</span>}
        {events.map((ev) => (
          <div key={ev.statementId} style={{ marginTop: 6 }}>
            <span>{ev.name}</span><span style={c.tag}>be a human</span>
            <button style={{ ...c.btn, marginLeft: 8, ...(!redeemed || !wallet || busy ? c.disabled : {}) }} disabled={!redeemed || !wallet || !!busy} onClick={() => join(ev)}>Join</button>
          </div>
        ))}
      </Step>
    </div>
  );
}

function Bob({ wallet, addLog }) {
  const [name, setName] = useState("Cannes 2026");
  const [events, setEvents] = useState([]);
  const [busy, setBusy] = useState(false);

  const refresh = async () => { try { setEvents((await api.events()).events); } catch {} };
  useEffect(() => { refresh(); }, []);

  const create = async () => {
    try { setBusy(true); const { tx } = await api.createEvent(name); await sendTx(tx); addLog(`event "${name}" created (statement registered)`, true); refresh(); }
    catch (e) { addLog(e.message, false); } finally { setBusy(false); }
  };

  return (
    <div style={c.card}>
      <h2 style={{ marginTop: 0 }}>Bob</h2>
      <div style={c.step}>
        <b>Create an event</b> — condition: <span style={c.tag}>be a human</span>
        <div style={{ marginTop: 8 }}>
          <input style={c.input} value={name} onChange={(e) => setName(e.target.value)} />
          <button style={{ ...c.btn, ...(!wallet || busy ? c.disabled : {}) }} disabled={!wallet || busy} onClick={create}>Create (MetaMask)</button>
        </div>
      </div>
      <div style={{ marginTop: 12 }}>
        <b>Events &amp; attendees</b>
        {events.length === 0 && <div style={c.muted}>none yet</div>}
        {events.map((ev) => (
          <div key={ev.statementId} style={c.step}>
            <div>{ev.name} <span style={c.mono}>{short(ev.statementId)}</span></div>
            <div style={c.muted}>attendees (nullifiers, not identities): {ev.attendees.length === 0 ? "—" : ev.attendees.map(short).join(", ")}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

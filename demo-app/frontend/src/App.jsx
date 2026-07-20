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
// World Chain Sepolia explorer (Etherscan family) for tx links.
const EXPLORER = "https://sepolia.worldscan.org/tx/";
const txHashOf = (rcpt) => rcpt?.hash || rcpt?.transactionHash;

export default function App() {
  const [wallet, setWallet] = useState(null);
  const [tab, setTab] = useState("alice");
  const [log, setLog] = useState([]);
  const addLog = (m, ok, url) => setLog((l) => [...l.slice(-40), { m, ok, url, t: new Date().toLocaleTimeString() }]);

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
              <div key={i} style={e.ok === false ? c.bad : e.ok ? c.ok : c.muted}>
                {e.t} {e.m}
                {e.url && <a href={e.url} target="_blank" rel="noreferrer" style={{ color: "#6c8cff", marginLeft: 6 }}>view on explorer ↗</a>}
              </div>
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
  const [ticket, setTicket] = useState(null); // Vouch: { subject, hasClaim, fact }
  const [emlFile, setEmlFile] = useState(null); // uploaded Luma confirmation .eml
  const [docFiles, setDocFiles] = useState([]); // batch of uploaded signed documents
  const [docResults, setDocResults] = useState([]); // per-file verify results
  const [proven, setProven] = useState([]); // accumulated facts [{ claimType, label }]
  const [validation, setValidation] = useState(null); // { statements, best }
  const [realParams, setRealParams] = useState(null); // Circuit-C proving params from backend
  const [proofFile, setProofFile] = useState(null); // bb target/proof
  const [pubFile, setPubFile] = useState(null); // bb target/public_inputs
  const [realStep, setRealStep] = useState(""); // sub-progress of the trustless path
  // One-shot (non-persistent) presentation
  const [osParams, setOsParams] = useState(null);
  const [osProof, setOsProof] = useState(null);
  const [osPub, setOsPub] = useState(null);
  const [osResult, setOsResult] = useState(null); // { presented, nullifier, eventLabel }
  const [osStep, setOsStep] = useState("");
  // Composition (multi-event, all in the browser)
  const [cxParams, setCxParams] = useState(null); // { events, label, ... }
  const [cxFiles, setCxFiles] = useState({}); // { [eventIdx]: File }
  const [cxStep, setCxStep] = useState("");
  const [cxResult, setCxResult] = useState(null); // { presented, label, nullifier }
  // Cross-type (World ID + events)
  const [widProof, setWidProof] = useState(null); // { root, nullifierHash, proofHex } captured in Step 2
  const [heParams, setHeParams] = useState(null);
  const [heFiles, setHeFiles] = useState({});
  const [heStep, setHeStep] = useState("");
  const [heResult, setHeResult] = useState(null);
  const [osEml, setOsEml] = useState(null); // uploaded Luma .eml for the in-browser path

  const refreshEvents = async () => {
    try {
      const next = (await api.events()).events;
      // Only update when the list actually changed, so an unchanged poll doesn't re-render Alice
      // (a re-render mid-scan would reset the World ID widget and swallow its onSuccess).
      setEvents((prev) => {
        const same = prev.length === next.length &&
          prev.every((e, i) => e.statementId === next[i]?.statementId && e.attendees.length === next[i]?.attendees.length);
        return same ? prev : next;
      });
    } catch {}
  };
  // Poll so events Bob creates after mount show up on Alice's side — but PAUSE while the World ID
  // modal is open, since re-renders during the scan break the widget.
  useEffect(() => {
    refreshEvents();
    if (open) return;
    const id = setInterval(refreshEvents, 3000);
    return () => clearInterval(id);
  }, [open]);

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
  // Also stash the raw proof so the cross-type gate (Step 8) can reuse it (same app+action+signal).
  const claimHumanity = async (result) => {
    setVerified(true);
    // IDKitRequestWidget returns { responses: [{ identifier, proof, merkle_root, nullifier }] }
    // (legacy V3 Orb: `proof` is the ABI-encoded uint256[8] the classic Router expects).
    const item =
      result?.responses?.find?.((x) => x.identifier === "proof_of_human") || result?.responses?.[0] || result;
    const proofHex = item?.proof;
    const root = item?.merkle_root ?? (Array.isArray(item?.proof) ? item.proof[4] : undefined);
    const nullifierHash = item?.nullifier ?? item?.nullifier_hash;
    if (typeof proofHex === "string" && root && nullifierHash) {
      setWidProof({ root, nullifierHash, proofHex });
      addLog("World ID proof captured for cross-type (Step 8)", true);
    } else {
      addLog("World ID: couldn't capture a legacy proof for on-chain use — keys: " + Object.keys(item || {}).join(","), false);
    }
    addLog("World ID verified — you're a unique human", true);
    try {
      setBusy("claim");
      setPhase("Depositing your credential… (approve in MetaMask)");
      const ins = await api.insertCredentialTx();
      await sendAndLog(ins.tx, "credential deposited (Part A)");
      setInserted(true);

      setPhase("Proving Circuit B & minting your claim… (approve in MetaMask)");
      const red = await api.redeem();
      await sendAndLog(red.tx, "humanity claim minted (Circuit B)");
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

  // Vouch (zkTLS): prove a Luma ticket by uploading the confirmation .eml. The backend verifies
  // Luma's DKIM signature over it (real cryptographic check), then issues EVENT_TICKET_LUMA.
  // Phase-1 pseudonymous: the subject is a stable per-recipient handle, separate from Alice's
  // unlinkable master identity.
  const readAsBase64 = (file) =>
    new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(String(r.result).split(",")[1]); // strip data: prefix
      r.onerror = reject;
      r.readAsDataURL(file);
    });

  const proveLumaTicket = async () => {
    try {
      if (!emlFile) throw new Error("choose your Luma confirmation .eml first");
      setBusy("ticket");
      addLog(`verifying DKIM signature on ${emlFile.name}…`, null);
      const emlBase64 = await readAsBase64(emlFile);
      const v = await api.vouchVerifyEmail(emlBase64); // throws if DKIM invalid / not from issuer
      addLog(`verified: email DKIM-signed by ${v.signingDomain} → ${v.fact.recipient}`, true);

      const at = await api.vouchAttestTx(v.subject);
      addLog("issuing EVENT_TICKET_LUMA claim… (approve in MetaMask)", null);
      await sendAndLog(at.tx, "EVENT_TICKET_LUMA attested");
      const claim = await api.vouchClaim(v.subject);
      setTicket({ subject: v.subject, hasClaim: claim.hasValidClaim, fact: v.fact });
      addLog(`ticket claim on-chain — hasValidClaim=${claim.hasValidClaim}`, claim.hasValidClaim);
    } catch (e) { addLog(e.message, false); } finally { setBusy(""); }
  };

  // Multi-document evidence: upload a batch of signed .eml, verify each (real DKIM, backend),
  // then Validate to see which statement the accumulated facts prove.
  const verifyDocs = async () => {
    try {
      if (docFiles.length === 0) throw new Error("choose one or more .eml files first");
      setBusy("docs");
      setValidation(null);
      addLog(`verifying ${docFiles.length} document(s)…`, null);
      const files = await Promise.all(
        docFiles.map(async (f) => ({ name: f.name, emlBase64: await readAsBase64(f) }))
      );
      const r = await api.verifyEmails(files);
      setDocResults(r.results);
      setProven(r.proven);
      const okN = r.results.filter((x) => x.ok).length;
      addLog(`verified ${okN}/${r.results.length} — proven facts: ${r.proven.map((p) => p.label).join(", ") || "none"}`, okN > 0);
    } catch (e) { addLog(e.message, false); } finally { setBusy(""); }
  };

  const validate = async () => {
    try {
      setBusy("validate");
      const v = await api.validate();
      setProven(v.proven);
      setValidation(v);
      addLog(v.best ? `statement proven: "${v.best.name}"` : "no complete statement yet", !!v.best);
    } catch (e) { addLog(e.message, false); } finally { setBusy(""); }
  };

  // --- Real Circuit-C path (trustless / private / unlinkable) for the Cannes source ----------
  const SOURCE_KEY = "luma:evt_cannes2026";
  const readBytesHex = (file) =>
    new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve("0x" + [...new Uint8Array(r.result)].map((b) => b.toString(16).padStart(2, "0")).join(""));
      r.onerror = reject;
      r.readAsArrayBuffer(file);
    });

  const getRealParams = async () => {
    try {
      setBusy("params");
      const p = await api.emailParams(SOURCE_KEY);
      setRealParams(p);
      addLog("proving params ready — prove Circuit C locally (see the command)", true);
    } catch (e) { addLog(e.message, false); } finally { setBusy(""); }
  };

  const submitEvidence = async () => {
    try {
      if (!proofFile || !pubFile) throw new Error("choose both the proof and public_inputs files (from bb)");
      setBusy("submit");
      setRealStep("Submitting evidence (Part A)… approve in MetaMask");
      const proofHex = await readBytesHex(proofFile);
      const pubHex = await readBytesHex(pubFile); // concatenated 32-byte fields
      const body = pubHex.slice(2);
      const pub = [];
      for (let i = 0; i < body.length; i += 64) pub.push("0x" + body.slice(i, i + 64));
      if (pub.length !== 5) throw new Error(`public_inputs should be 5 fields, got ${pub.length}`);
      const { tx } = await api.submitEvidenceTx(SOURCE_KEY, proofHex, pub);
      await sendAndLog(tx, "evidence accepted — credential inserted (Part A)");

      setRealStep("Redeeming into your identity (Part B)… approve in MetaMask");
      const red = await api.redeemEmailTx(SOURCE_KEY);
      await sendAndLog(red.tx, `claim ${red.claimTypeName} minted (Circuit B)`);
      setRealStep("");
      validate();
    } catch (e) { addLog(e.message, false); setRealStep("failed — " + e.message); } finally { setBusy(""); }
  };

  // --- One-shot presentation (non-persistent): prove a real Luma email locally, present in 1 tx --
  const getOsParams = async () => {
    try {
      if (!wallet) throw new Error("connect wallet first");
      setBusy("osparams");
      const p = await api.oneshotParams(address());
      setOsParams(p);
      addLog("one-shot params ready — prove the Luma email locally (see the command)", true);
    } catch (e) { addLog(e.message, false); } finally { setBusy(""); }
  };

  // One-click: read the .eml, generate inputs + prove IN THE BROWSER (email never leaves the
  // device), then present on-chain — no WSL, no backend seeing the email.
  const proveAndPresentInBrowser = async () => {
    try {
      if (!osEml) throw new Error("choose your Luma .eml first");
      if (!osParams) throw new Error("get proving params first");
      setBusy("osbrowser");
      setOsResult(null);
      setOsStep("Reading email + generating inputs on your device…");
      const emlText = await osEml.text();
      const { buildOneshotInput } = await import("./oneshotInputs.js");
      const { input, event } = await buildOneshotInput(emlText, {
        secret: osParams.secret, caller: address(), statementId: osParams.statementId, contextId: osParams.contextId,
      });

      const { proveInBrowser, proofToHex } = await import("./browserProve.js");
      const res = await proveInBrowser(input, (s) => setOsStep(`Proving in your browser (~30s): ${s}`));
      addLog(`browser proof done in ${(res.timings.totalMs / 1000).toFixed(1)}s`, true);

      setOsStep("Presenting on-chain (1 tx)… approve in MetaMask");
      const { tx, nullifier } = await api.oneshotPresentTx(proofToHex(res.proof), res.publicInputs);
      await sendAndLog(tx, "one-shot present");
      const { presented } = await api.oneshotPresented(nullifier);
      setOsResult({ presented, nullifier, eventLabel: `Attended "${event}"` });
      addLog(`presented in-browser — "${event}" (burned=${presented})`, presented);
      setOsStep("");
    } catch (e) { addLog(e.message, false); setOsStep("failed — " + e.message); } finally { setBusy(""); }
  };

  const presentOneshot = async () => {
    try {
      if (!osProof || !osPub) throw new Error("choose both the proof and public_inputs files");
      setBusy("ospresent");
      setOsStep("Presenting on-chain (1 tx)… approve in MetaMask");
      const proofHex = await readBytesHex(osProof);
      const body = (await readBytesHex(osPub)).slice(2);
      const pub = [];
      for (let i = 0; i < body.length; i += 64) pub.push("0x" + body.slice(i, i + 64));
      if (pub.length !== 6) throw new Error(`public_inputs should be 6 fields, got ${pub.length}`);
      const { tx, nullifier } = await api.oneshotPresentTx(proofHex, pub);
      await sendAndLog(tx, "one-shot present");
      const { presented } = await api.oneshotPresented(nullifier);
      setOsResult({ presented, nullifier, eventLabel: osParams.eventLabel });
      addLog(`presented on-chain — "${osParams.eventLabel}" (nullifier burned=${presented})`, presented);
      setOsStep("");
    } catch (e) { addLog(e.message, false); setOsStep("failed — " + e.message); } finally { setBusy(""); }
  };

  // Send a tx and log its hash with a clickable World Chain Sepolia explorer link (Etherscan family).
  const sendAndLog = async (tx, label) => {
    const rcpt = await sendTx(tx);
    const hash = txHashOf(rcpt);
    addLog(`${label} — tx ${short(hash)}`, true, hash ? EXPLORER + hash : undefined);
    return rcpt;
  };

  // --- Cross-type: World ID (from Step 2) + a browser email proof per event, one present() tx ----
  const loadHuman = async () => {
    try {
      if (!wallet) throw new Error("connect wallet first");
      setBusy("heload");
      setHeParams(await api.humanParams(address()));
    } catch (e) { addLog(e.message, false); } finally { setBusy(""); }
  };

  const presentHuman = async () => {
    try {
      if (!widProof) throw new Error("prove World ID first (Step 2)");
      const params = heParams || (await api.humanParams(address()));
      const files = params.events.map((_, i) => heFiles[i]);
      if (files.some((f) => !f)) throw new Error("choose an .eml for each event");
      setBusy("human");
      setHeResult(null);

      const { buildOneshotInputs } = await import("./browserInputs.js");
      const { proveInBrowser, proofToHex } = await import("./browserProve.js");
      // Fresh context each run so the same World ID human can re-present (one human per instance).
      const ctx = String(Math.floor(Date.now() / 1000));
      const proofs = [], pubs = [];
      for (let i = 0; i < params.events.length; i++) {
        setHeStep(`Email ${i + 1}/${params.events.length}: build + prove in browser…`);
        const { inputMap, event } = await buildOneshotInputs({
          emlText: await files[i].text(), secret: params.secret, caller: address(),
          statementId: params.statementId, contextId: ctx,
        });
        const { proof, publicInputs } = await proveInBrowser(inputMap);
        proofs.push(proofToHex(proof)); pubs.push(publicInputs);
        addLog(`proved "${event}" in the browser`, true);
      }

      // Decode the IDKit proof string into the uint256[8] the contract expects.
      const { AbiCoder } = await import("ethers");
      const proof8 = AbiCoder.defaultAbiCoder().decode(["uint256[8]"], widProof.proofHex)[0].map((x) => x.toString());
      const wid = { root: widProof.root, nullifierHash: widProof.nullifierHash, proof: proof8 };

      setHeStep("Presenting: verified human + all events (1 tx)… approve in MetaMask");
      const { tx, humanNullifier, contextId } = await api.humanPresentTx(wid, proofs, pubs);
      await sendAndLog(tx, "cross-type present");
      const { presented } = await api.humanPresented(contextId, humanNullifier);
      setHeResult({ presented, label: params.label });
      addLog(`cross-type presented — "${params.label}" (burned=${presented})`, presented);
      setHeStep("");
    } catch (e) { addLog(e.message, false); setHeStep("failed — " + e.message); } finally { setBusy(""); }
  };

  const loadCompose = async () => {
    try {
      if (!wallet) throw new Error("connect wallet first");
      setBusy("cxload");
      setCxParams(await api.composeParams(address()));
    } catch (e) { addLog(e.message, false); } finally { setBusy(""); }
  };

  // --- Composition: upload the emails, prove EACH in the browser, present them together (1 tx) ---
  const composeAll = async () => {
    try {
      if (!wallet) throw new Error("connect wallet first");
      setBusy("compose");
      setCxResult(null);
      const params = cxParams || (await api.composeParams(address()));
      const files = params.events.map((_, i) => cxFiles[i]);
      if (files.some((f) => !f)) throw new Error("choose an .eml for each event");

      const { buildOneshotInputs } = await import("./browserInputs.js");
      const { proveInBrowser, proofToHex } = await import("./browserProve.js");

      const proofs = [];
      const pubs = [];
      for (let i = 0; i < params.events.length; i++) {
        setCxStep(`Email ${i + 1}/${params.events.length}: reading + building inputs (in browser)…`);
        const emlText = await files[i].text();
        const { inputMap, event } = await buildOneshotInputs({
          emlText, secret: params.secret, caller: address(),
          statementId: params.statementId, contextId: params.contextId,
        });
        setCxStep(`Email ${i + 1}/${params.events.length}: proving "${event}" (~25s, in browser)…`);
        const { proof, publicInputs } = await proveInBrowser(inputMap);
        proofs.push(proofToHex(proof));
        pubs.push(publicInputs);
        addLog(`proved "${event}" in the browser`, true);
      }

      setCxStep("Presenting the conjunction on-chain (1 tx)… approve in MetaMask");
      const { tx, nullifier } = await api.composePresentTx(proofs, pubs);
      await sendAndLog(tx, "compose present");
      const { presented } = await api.composePresented(nullifier);
      setCxResult({ presented, label: params.label, nullifier });
      addLog(`composed on-chain — "${params.label}" (burned=${presented})`, presented);
      setCxStep("");
    } catch (e) { addLog(e.message, false); setCxStep("failed — " + e.message); } finally { setBusy(""); }
  };

  const join = async (ev) => {
    try {
      setBusy("join" + ev.statementId);
      addLog(`proving Circuit A for "${ev.name}"…`, null);
      const { tx, nullifier } = await api.join(ev.statementId, address());
      await sendAndLog(tx, `joined "${ev.name}" (nullifier ${short(nullifier)})`);
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

      <Step n={4} title="Prove a Luma ticket (Vouch · DKIM)" done={!!ticket?.hasClaim}>
        <div style={{ ...c.muted, marginBottom: 8 }}>
          A 3rd provider: upload your Luma confirmation email. The backend verifies Luma's
          <code style={c.mono}> DKIM</code> signature over it (a real check — forgeries fail), then issues an
          <code style={c.mono}> EVENT_TICKET_LUMA</code> claim on-chain. Phase-1 pseudonymous.
        </div>
        <input type="file" accept=".eml,message/rfc822" onChange={(e) => setEmlFile(e.target.files?.[0] || null)}
          style={{ ...c.mono, marginBottom: 8, display: "block" }} />
        {emlFile && <div style={{ ...c.mono, ...c.ok, marginBottom: 8 }}>selected: {emlFile.name}</div>}
        <button style={{ ...c.btn, ...(!wallet || !emlFile || busy ? c.disabled : {}) }} disabled={!wallet || !emlFile || !!busy} onClick={proveLumaTicket}>
          {busy === "ticket" ? "Verifying…" : "Verify & claim ticket"}
        </button>
        <div style={{ marginTop: 6 }}>
          <span style={ticket ? c.ok : c.muted}>ticket verified {ticket ? "✓" : "—"}</span>
          <span style={{ ...(ticket?.hasClaim ? c.ok : c.muted), marginLeft: 14 }}>claim on-chain {ticket?.hasClaim ? "✓" : "—"}</span>
        </div>
        {ticket && <div style={{ ...c.mono, marginTop: 6 }}>{ticket.fact?.issuer} · {ticket.fact?.recipient} · subject {short(ticket.subject)}</div>}
      </Step>

      <Step n={5} title="Prove facts from documents → validate a statement" done={!!validation?.best}>
        <div style={{ ...c.muted, marginBottom: 8 }}>
          Drop in a batch of <b>signed</b> emails (Luma ticket, university enrollment, tax receipt…).
          Each one's <code style={c.mono}>DKIM</code> signature is verified (real check — forgeries and
          unsigned files are rejected) and mapped to a fact. Then <b>Validate</b> tells you which
          statement your facts (+ humanity) prove. <span style={c.muted}>Generate samples with
          <code style={c.mono}> node make-evidence-samples.mjs</code>.</span>
        </div>
        <input type="file" accept=".eml,message/rfc822" multiple
          onChange={(e) => { setDocFiles([...(e.target.files || [])]); setDocResults([]); setValidation(null); }}
          style={{ ...c.mono, marginBottom: 8, display: "block" }} />
        {docFiles.length > 0 && <div style={{ ...c.mono, ...c.ok, marginBottom: 8 }}>{docFiles.length} file(s): {docFiles.map((f) => f.name).join(", ")}</div>}
        <button style={{ ...c.btn, ...(docFiles.length === 0 || busy ? c.disabled : {}) }} disabled={docFiles.length === 0 || !!busy} onClick={verifyDocs}>
          {busy === "docs" ? "Verifying…" : "Verify documents"}
        </button>
        <button style={{ ...c.btn, ...c.ghost, ...(busy ? c.disabled : {}) }} disabled={!!busy} onClick={validate}>
          {busy === "validate" ? "Validating…" : "Validate"}
        </button>

        {docResults.length > 0 && (
          <div style={{ marginTop: 10 }}>
            {docResults.map((r, i) => (
              <div key={i} style={{ ...c.mono, color: r.ok ? "#35d07f" : "#ff6b6b", padding: "2px 0" }}>
                {r.ok ? "✓" : "✕"} {r.name} — {r.ok ? `${r.label} (signed by ${r.signingDomain})` : r.reason}
              </div>
            ))}
          </div>
        )}

        {proven.length > 0 && (
          <div style={{ marginTop: 10 }}>
            <span style={c.muted}>facts held: </span>
            {proven.map((p) => <span key={p.claimType} style={c.tag}>{p.label}</span>)}
          </div>
        )}

        {validation && (
          <div style={{ marginTop: 12, padding: 12, background: "#0b0e1a", border: "1px solid #2c3355", borderRadius: 10 }}>
            {validation.best
              ? <div style={{ ...c.ok, fontWeight: 700, marginBottom: 8 }}>✓ You've proven: “{validation.best.name}”</div>
              : <div style={{ ...c.muted, marginBottom: 8 }}>No complete statement yet — add the missing facts below.</div>}
            {validation.statements.map((s) => (
              <div key={s.name} style={{ padding: "3px 0" }}>
                <span style={s.satisfied ? c.ok : c.muted}>{s.satisfied ? "✓" : "○"} {s.name}</span>
                {!s.satisfied && <span style={{ ...c.mono, ...c.muted }}> — missing: {s.missing.map((m) => m.label).join(", ")}</span>}
              </div>
            ))}
          </div>
        )}

        {/* --- the trustless / private / unlinkable path (real Circuit C) --- */}
        <div style={{ marginTop: 16, paddingTop: 12, borderTop: "1px solid #2c3355" }}>
          <div style={{ fontWeight: 700, marginBottom: 4 }}>Trustless path (real Circuit C) — Cannes ticket</div>
          <div style={{ ...c.muted, marginBottom: 8 }}>
            The version above verifies DKIM <b>on the backend</b> (fast, but the server sees your email and
            nothing binds it to you). This path fixes all three: the <b>email is proven on your machine</b>
            (backend never sees it), the proof <b>binds your identity</b> (<code style={c.mono}>C</code>) and
            <b> consumes a one-time nullifier on-chain</b>, and the claim lands <b>unlinkably</b>.
          </div>

          <button style={{ ...c.btn, ...(!wallet || busy ? c.disabled : {}) }} disabled={!wallet || !!busy} onClick={getRealParams}>
            1. Get proving params
          </button>

          {realParams && (
            <div style={{ marginTop: 8 }}>
              <div style={{ ...c.muted, marginBottom: 4 }}>2. Prove Circuit C locally (WSL) over <b>your</b> .eml — the email never leaves your disk:</div>
              <div style={{ ...c.mono, background: "#0b0e1a", border: "1px solid #2c3355", borderRadius: 8, padding: 10, overflowX: "auto", whiteSpace: "pre", fontSize: 11 }}>
{`# in demo-app/backend  (regenerate so the nullifier is fresh)
node make-test-eml.mjs
node make-email-proof-inputs.mjs sample-luma.eml ${realParams.token} \\
  ${realParams.secret} \\
  ${realParams.r}
# in email_proof/  (nargo 1.0.0-beta.5 + matching bb):
nargo execute   # prints [kh0, kh1, event_id, nullifier, C] — copy kh0, kh1
bb prove --scheme ultra_honk --oracle_hash keccak \\
  -b target/email_proof.json -w target/email_proof.gz -o target
# register the fresh DKIM key on-chain (owner tx), then upload the 2 files below:
# cast send ${"0x7E132c95bb1ee268271b6BE44271808072Bd7F66"} \\
#   "registerKey(bytes32,bytes32,bytes32)" \\
#   $(cast keccak "lu.ma") <kh0> <kh1> --rpc-url $RPC --account dev`}
              </div>

              <div style={{ marginTop: 10, display: "flex", flexDirection: "column", gap: 8 }}>
                <div style={c.mono}>
                  proof: <input type="file" onChange={(e) => setProofFile(e.target.files?.[0] || null)} />
                  {proofFile && <span style={c.ok}> ✓ {proofFile.name} ({proofFile.size} bytes)</span>}
                </div>
                <div style={c.mono}>
                  public_inputs: <input type="file" onChange={(e) => setPubFile(e.target.files?.[0] || null)} />
                  {pubFile && <span style={c.ok}> ✓ {pubFile.name} ({pubFile.size} bytes)</span>}
                </div>
              </div>

              <button style={{ ...c.btn, marginTop: 10, ...(!proofFile || !pubFile || busy ? c.disabled : {}) }}
                disabled={!proofFile || !pubFile || !!busy} onClick={submitEvidence}>
                3. Submit on-chain (evidence → redeem)
              </button>
              {realStep && <div style={{ ...c.muted, marginTop: 6 }}>{realStep}</div>}
            </div>
          )}
        </div>
      </Step>

      <Step n={6} title="Prove a real Luma event — one-shot (nothing stored)" done={!!osResult?.presented}>
        <div style={{ ...c.muted, marginBottom: 8 }}>
          The <b>non-persistent</b> path: prove a <b>real Luma confirmation email</b> on your machine and
          present it in <b>one transaction</b> — no claim, no credential tree, no redeem. The gate learns
          only <i>"attended this event, nullifier X"</i>: bound to you (non-transferable), unlinkable across
          apps, and <b>nothing is saved on-chain</b> beyond the burned nullifier.
        </div>

        <button style={{ ...c.btn, ...(!wallet || busy ? c.disabled : {}) }} disabled={!wallet || !!busy} onClick={getOsParams}>
          1. Get proving params
        </button>

        {osParams && (
          <div style={{ marginTop: 10, padding: 12, background: "#101830", border: "1px solid #35d07f55", borderRadius: 10 }}>
            <div style={{ fontWeight: 700, ...c.ok, marginBottom: 6 }}>2. Prove in your browser (one click — no WSL)</div>
            <div style={{ ...c.muted, marginBottom: 8 }}>
              Upload your real Luma confirmation <code style={c.mono}>.eml</code>. It's parsed and proven
              <b> entirely on your device</b> (~30s) — the email never reaches any server — then presented on-chain.
            </div>
            <input type="file" accept=".eml,message/rfc822" onChange={(e) => setOsEml(e.target.files?.[0] || null)}
              style={{ ...c.mono, marginBottom: 8, display: "block" }} />
            {osEml && <div style={{ ...c.mono, ...c.ok, marginBottom: 8 }}>selected: {osEml.name}</div>}
            <button style={{ ...c.btn, ...(!osEml || !wallet || busy ? c.disabled : {}) }}
              disabled={!osEml || !wallet || !!busy} onClick={proveAndPresentInBrowser}>
              {busy === "osbrowser" ? "Working…" : "Prove in browser & present (1 tx)"}
            </button>
            {busy === "osbrowser" && osStep && <div style={{ ...c.muted, marginTop: 6 }}>{osStep}</div>}
          </div>
        )}

        {osParams && (
          <details style={{ marginTop: 10 }}>
            <summary style={{ ...c.muted, cursor: "pointer" }}>Advanced: prove locally (WSL) instead</summary>
            <div style={{ ...c.muted, marginBottom: 4, marginTop: 8 }}>
              Prove locally (WSL, nargo 1.0.0-beta.5) over your <code style={c.mono}>{osParams.sampleEml}</code> —
              the email never leaves your disk:
            </div>
            <div style={{ ...c.mono, background: "#0b0e1a", border: "1px solid #2c3355", borderRadius: 8, padding: 10, overflowX: "auto", whiteSpace: "pre", fontSize: 11 }}>
{`# in demo-app/backend
${osParams.command}
# in email_oneshot_proof/
nargo execute && bb prove --scheme ultra_honk --oracle_hash keccak \\
  -b target/email_oneshot_proof.json -w target/email_oneshot_proof.gz -o target
# then upload target/proof and target/public_inputs below`}
            </div>

            <div style={{ marginTop: 10, display: "flex", flexDirection: "column", gap: 8 }}>
              <div style={c.mono}>
                proof: <input type="file" onChange={(e) => setOsProof(e.target.files?.[0] || null)} />
                {osProof && <span style={c.ok}> ✓ {osProof.name} ({osProof.size} bytes)</span>}
              </div>
              <div style={c.mono}>
                public_inputs: <input type="file" onChange={(e) => setOsPub(e.target.files?.[0] || null)} />
                {osPub && <span style={c.ok}> ✓ {osPub.name} ({osPub.size} bytes)</span>}
              </div>
            </div>

            <button style={{ ...c.btn, marginTop: 10, ...(!osProof || !osPub || busy ? c.disabled : {}) }}
              disabled={!osProof || !osPub || !!busy} onClick={presentOneshot}>
              3. Present on-chain (1 tx)
            </button>
          </details>
        )}

        {busy !== "osbrowser" && osStep && <div style={{ ...c.muted, marginTop: 6 }}>{osStep}</div>}
        {osResult && (
          <div style={{ marginTop: 10, padding: 12, background: "#0b0e1a", border: "1px solid #2c3355", borderRadius: 10 }}>
            <div style={{ ...(osResult.presented ? c.ok : c.bad), fontWeight: 700 }}>
              {osResult.presented ? "✓" : "✕"} {osResult.eventLabel}
            </div>
            <div style={{ ...c.mono, ...c.muted, marginTop: 4 }}>nullifier {short(osResult.nullifier)} — burned on-chain, nothing else stored</div>
          </div>
        )}
      </Step>

      <Step n={7} title="Compose: attend BOTH events — proved entirely in the browser" done={!!cxResult?.presented}>
        <div style={{ ...c.muted, marginBottom: 8 }}>
          The full vision: upload a real Luma email for <b>each</b> required event, and the browser
          proves them all (<code style={c.mono}>~25s each</code>, emails never leave your device) and
          presents them in <b>one transaction</b>. The gate accepts only if every event is covered and
          all proofs share one nullifier — <b>the same person attended both</b>. No WSL, nothing stored.
        </div>

        <button style={{ ...c.btn, ...(!wallet || busy ? c.disabled : {}) }} disabled={!wallet || !!busy} onClick={loadCompose}>
          Load required events
        </button>

        {cxParams && (
          <div style={{ marginTop: 10 }}>
            {cxParams.events.map((ev, i) => (
              <div key={i} style={{ ...c.mono, padding: "4px 0" }}>
                <span style={c.tag}>event {i + 1}</span> {ev.label}
                <div style={{ marginTop: 4 }}>
                  <input type="file" accept=".eml,message/rfc822"
                    onChange={(e) => setCxFiles((f) => ({ ...f, [i]: e.target.files?.[0] || null }))} />
                  {cxFiles[i] && <span style={c.ok}> ✓ {cxFiles[i].name}</span>}
                  <span style={{ ...c.muted, marginLeft: 8 }}>(sample: {ev.sampleEml})</span>
                </div>
              </div>
            ))}
            <button style={{ ...c.btn, marginTop: 10, ...(cxParams.events.some((_, i) => !cxFiles[i]) || busy ? c.disabled : {}) }}
              disabled={cxParams.events.some((_, i) => !cxFiles[i]) || !!busy} onClick={composeAll}>
              {busy === "compose" ? "Proving…" : "Prove all in browser → present (1 tx)"}
            </button>
            {cxStep && <div style={{ ...c.muted, marginTop: 6 }}>{cxStep}</div>}
            {cxResult && (
              <div style={{ marginTop: 10, padding: 12, background: "#0b0e1a", border: "1px solid #2c3355", borderRadius: 10 }}>
                <div style={{ ...(cxResult.presented ? c.ok : c.bad), fontWeight: 700 }}>
                  {cxResult.presented ? "✓ You've proven: " + cxResult.label : "✕ not accepted"}
                </div>
                <div style={{ ...c.mono, ...c.muted, marginTop: 4 }}>shared nullifier {short(cxResult.nullifier)} — one person, both events, nothing stored</div>
              </div>
            )}
          </div>
        )}
      </Step>

      <Step n={8} title="Cross-type: a verified HUMAN who attended these events" done={!!heResult?.presented}>
        <div style={{ ...c.muted, marginBottom: 8 }}>
          The full composite: <b>World ID personhood</b> (from Step 2) <b>AND</b> a real Luma email per
          event, verified together in <b>one transaction</b>. Two different proof systems, bound to your
          wallet — "the same person is a verified human <i>and</i> attended these events." Sybil-safe
          (one human per context), nothing stored.
        </div>
        <div style={{ marginBottom: 8 }}>
          <span style={widProof ? c.ok : c.muted}>World ID {widProof ? "✓ captured (Step 2)" : "— do Step 2 first"}</span>
        </div>

        <button style={{ ...c.btn, ...(!wallet || busy ? c.disabled : {}) }} disabled={!wallet || !!busy} onClick={loadHuman}>
          Load required events
        </button>

        {heParams && (
          <div style={{ marginTop: 10 }}>
            {heParams.events.map((ev, i) => (
              <div key={i} style={{ ...c.mono, padding: "4px 0" }}>
                <span style={c.tag}>event {i + 1}</span> {ev.label}
                <div style={{ marginTop: 4 }}>
                  <input type="file" accept=".eml,message/rfc822"
                    onChange={(e) => setHeFiles((f) => ({ ...f, [i]: e.target.files?.[0] || null }))} />
                  {heFiles[i] && <span style={c.ok}> ✓ {heFiles[i].name}</span>}
                  <span style={{ ...c.muted, marginLeft: 8 }}>(sample: {ev.sampleEml})</span>
                </div>
              </div>
            ))}
            <button style={{ ...c.btn, marginTop: 10, ...(!widProof || heParams.events.some((_, i) => !heFiles[i]) || busy ? c.disabled : {}) }}
              disabled={!widProof || heParams.events.some((_, i) => !heFiles[i]) || !!busy} onClick={presentHuman}>
              {busy === "human" ? "Proving…" : "Prove human + events in browser → present (1 tx)"}
            </button>
            {heStep && <div style={{ ...c.muted, marginTop: 6 }}>{heStep}</div>}
            {heResult && (
              <div style={{ marginTop: 10, padding: 12, background: "#0b0e1a", border: "1px solid #2c3355", borderRadius: 10 }}>
                <div style={{ ...(heResult.presented ? c.ok : c.bad), fontWeight: 700 }}>
                  {heResult.presented ? "✓ You've proven: " + heResult.label : "✕ not accepted"}
                </div>
                <div style={{ ...c.mono, ...c.muted, marginTop: 4 }}>World ID + email events, one wallet, one tx — nothing stored</div>
              </div>
            )}
          </div>
        )}
      </Step>
    </div>
  );
}

function Bob({ wallet, addLog }) {
  const [name, setName] = useState("Cannes 2026");
  const [events, setEvents] = useState([]);
  const [busy, setBusy] = useState(false);

  const refresh = async () => { try { setEvents((await api.events()).events); } catch {} };
  useEffect(() => { refresh(); const id = setInterval(refresh, 3000); return () => clearInterval(id); }, []);

  const create = async () => {
    try {
      setBusy(true);
      const { tx } = await api.createEvent(name);
      const rcpt = await sendTx(tx);
      const hash = txHashOf(rcpt);
      addLog(`event "${name}" created (statement registered) — tx ${short(hash)}`, true, hash ? EXPLORER + hash : undefined);
      refresh();
    }
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

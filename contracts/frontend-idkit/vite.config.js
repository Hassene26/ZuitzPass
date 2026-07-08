import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";
import { nodePolyfills } from "vite-plugin-node-polyfills";
import { signRequest } from "@worldcoin/idkit-server";

// World ID 4 requires each verification request to carry an RP (relying-party) signature,
// produced server-side from your SECRET signing key. This Vite plugin hosts that signing
// endpoint inside the dev server, so the key (RP_SIGNING_KEY) never reaches the browser.
// IDKit v4's core is Rust/WASM. Vite's dev server doesn't tag .wasm as application/wasm, which
// triggers a slow-path warning (and can fail on stricter setups). Set the MIME type explicitly.
function wasmMimePlugin() {
  return {
    name: "wasm-mime",
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        if (req.url && req.url.split("?")[0].endsWith(".wasm")) {
          res.setHeader("Content-Type", "application/wasm");
        }
        next();
      });
    },
  };
}

function rpSignaturePlugin(env) {
  return {
    name: "rp-signature-endpoint",
    configureServer(server) {
      server.middlewares.use("/api/rp-signature", (req, res) => {
        if (req.method !== "POST") {
          res.statusCode = 405;
          return res.end("POST only");
        }
        let body = "";
        req.on("data", (c) => (body += c));
        req.on("end", () => {
          try {
            if (!env.RP_SIGNING_KEY) throw new Error("RP_SIGNING_KEY not set in .env");
            const { action } = JSON.parse(body || "{}");
            // orbLegacy is a per-action (uniqueness) proof, so the action is signed in.
            const sig = signRequest({ signingKeyHex: env.RP_SIGNING_KEY, action });
            res.setHeader("content-type", "application/json");
            res.end(JSON.stringify({ rp_id: env.VITE_RP_ID, ...sig }));
          } catch (e) {
            res.statusCode = 500;
            res.setHeader("content-type", "application/json");
            res.end(JSON.stringify({ error: String(e?.message || e) }));
          }
        });
      });
    },
  };
}

export default defineConfig(({ mode }) => {
  // Load ALL env vars (incl. the non-VITE_ secret) into the node/config context only.
  const env = loadEnv(mode, process.cwd(), "");
  return {
    // nodePolyfills shims Node builtins that IDKit's bridge pulls in (why a raw CDN <script> fails).
    // Keep @worldcoin/idkit in the pre-bundler so its CommonJS dep `qrcode` is converted to ESM,
    // but EXCLUDE @worldcoin/idkit-core (the WASM package): the optimizer relocates its .wasm to
    // .vite/deps and the runtime URL then mis-resolves to index.html (the `<!do…`/magic-word
    // error). Excluding it makes Vite serve the real idkit_wasm_bg.wasm from node_modules.
    optimizeDeps: { exclude: ["@worldcoin/idkit-core"] },
    plugins: [react(), nodePolyfills(), wasmMimePlugin(), rpSignaturePlugin(env)],
    server: { port: 5174 },
  };
});

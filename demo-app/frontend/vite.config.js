import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { nodePolyfills } from "vite-plugin-node-polyfills";

// nodePolyfills + wasm MIME are needed for IDKit v4 (World ID) — same as contracts/frontend-idkit.
function wasmMime() {
  return {
    name: "wasm-mime",
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        if (req.url && req.url.split("?")[0].endsWith(".wasm")) res.setHeader("Content-Type", "application/wasm");
        next();
      });
    },
  };
}

export default defineConfig({
  plugins: [react(), nodePolyfills(), wasmMime()],
  // bb.js + noir_js ship WASM and use top-level await / workers — don't pre-bundle them (so their
  // .wasm assets resolve) and target esnext.
  optimizeDeps: {
    exclude: ["@worldcoin/idkit-core", "@aztec/bb.js", "@noir-lang/noir_js", "@noir-lang/noirc_abi", "@noir-lang/acvm_js"],
    esbuildOptions: { target: "esnext" },
  },
  build: { target: "esnext" },
  worker: { format: "es" },
  server: {
    port: 5175,
    proxy: { "/api": "http://localhost:8787" }, // backend
    // NOTE: no COOP/COEP headers — they'd break the IDKit World-ID iframe. bb.js falls back to
    // single-threaded proving without SharedArrayBuffer (slower but works; ~27s for this circuit).
  },
});

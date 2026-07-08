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
  optimizeDeps: { exclude: ["@worldcoin/idkit-core"] },
  server: {
    port: 5175,
    proxy: { "/api": "http://localhost:8787" }, // backend
  },
});

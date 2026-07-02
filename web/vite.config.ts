import basicSsl from "@vitejs/plugin-basic-ssl";
import { defineConfig } from "vite";
import { resolve } from "node:path";

// HTTPS + host exposure so the webcam works when testing on a phone over LAN
// (getUserMedia requires a secure context; accept the self-signed cert once).
//
// CHAMBER_LIVE=1  → plain HTTP for the live bridge (localhost camera still works).
// CHAMBER_HTTP=1  → plain HTTP for the localhost-only sandbox (camera still works on
// localhost — it's a secure context — without the self-signed-cert warning).
const live = process.env.CHAMBER_LIVE === "1";
const noSsl = live || process.env.CHAMBER_HTTP === "1";

export default defineConfig({
  plugins: noSsl ? [] : [basicSsl()],
  server: { host: true, open: true },
  build: {
    target: "es2022",
    sourcemap: true,
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
        sandbox: resolve(__dirname, "sandbox.html"),
      },
    },
  },
});

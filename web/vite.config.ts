import basicSsl from "@vitejs/plugin-basic-ssl";
import { defineConfig } from "vite";
import { resolve } from "node:path";

// HTTPS + host exposure so the webcam works when testing on a phone over LAN
// (getUserMedia requires a secure context; accept the self-signed cert once).
//
// CHAMBER_LIVE=1  → plain HTTP for the live bridge (localhost camera still works).
// CHAMBER_DEV=1   → enables the test harness's 3D head-view (`just harness-dev`).
const live = process.env.CHAMBER_LIVE === "1";
// The harness is localhost-only and uses no camera, so it runs over plain HTTP (no
// self-signed-cert warning). HTTPS stays on for the Chamber app (it needs the webcam).
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
        test: resolve(__dirname, "test.html"),
      },
    },
  },
});

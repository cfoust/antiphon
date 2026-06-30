import basicSsl from "@vitejs/plugin-basic-ssl";
import { defineConfig } from "vite";
import { resolve } from "node:path";

// HTTPS + host exposure so the webcam works when testing on a phone over LAN
// (getUserMedia requires a secure context; accept the self-signed cert once).
//
// CHAMBER_LIVE=1  → plain HTTP for the live bridge (localhost camera still works).
// CHAMBER_DEV=1   → enables the test harness's 3D head-view (`just harness-dev`).
const live = process.env.CHAMBER_LIVE === "1";
const dev3d = process.env.CHAMBER_DEV === "1";

export default defineConfig({
  plugins: live ? [] : [basicSsl()],
  server: { host: true, open: true },
  define: { __DEV3D__: JSON.stringify(dev3d) },
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

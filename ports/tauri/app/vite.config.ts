import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";

const WEB_RUNTIME_MARKER = '{"schemaVersion":1,"runtime":"simulator-only-web"}\n';

function webRuntimeMarker(): Plugin {
  return {
    name: "scanstudio-web-runtime-marker",
    generateBundle() {
      this.emitFile({
        type: "asset",
        fileName: "scanstudio-web-runtime.json",
        source: WEB_RUNTIME_MARKER,
      });
    },
  };
}

// @ts-expect-error process is a nodejs global
const host = process.env.TAURI_DEV_HOST;
// @ts-expect-error process is a nodejs global
const webGateway = process.env.SCANSTUDIO_WEB_GATEWAY || "http://127.0.0.1:8787";

// https://vite.dev/config/
export default defineConfig(async ({ mode }) => ({
  plugins: [react(), ...(mode === "web" ? [webRuntimeMarker()] : [])],

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent Vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // 3. tell Vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
    proxy:
      mode === "web"
        ? {
            "/api": { target: webGateway, ws: true },
            "/healthz": { target: webGateway },
          }
        : undefined,
  },
}));

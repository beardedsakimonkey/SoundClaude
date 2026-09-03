import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import stylex from "@stylexjs/unplugin";
import type { Plugin } from "vite";

function reactDevtools(): Plugin {
  return {
    name: "react-devtools",
    apply: "serve",
    transformIndexHtml: {
      order: "pre",
      handler: () => [
        {
          tag: "script",
          attrs: { src: "http://localhost:8097" },
          injectTo: "head-prepend",
        },
      ],
    },
  };
}

export default defineConfig(({ mode }) => ({
  plugins: [
    reactDevtools(),
    ...(mode === "test" ? [] : [stylex.vite({ useCSSLayers: true })]),
    react(),
  ],
  clearScreen: false,
  server: {
    host: "127.0.0.1",
    port: 1420,
    strictPort: true,
  },
  envPrefix: ["VITE_", "TAURI_ENV_*"],
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
    clearMocks: true,
    globals: true,
  },
}));

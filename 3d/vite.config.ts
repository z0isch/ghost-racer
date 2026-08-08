import { defineConfig } from "vite";

export default defineConfig({
  // Relative base so a `vite build` can be opened from the filesystem.
  base: "./",
  server: { open: false },
  build: { target: "es2022", sourcemap: true },
});

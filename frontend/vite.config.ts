import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [react()],
  test: {
    environment: "jsdom",
    setupFiles: "./src/shared/test/setupTests.ts",
    include: ["tests/**/*.{test,spec}.{ts,tsx}"],
    coverage: {
      provider: "v8",
      reporter: ["text", "html"],
      all: true,
      include: ["src/**/*.{ts,tsx}"],
      exclude: ["src/vite-env.d.ts", "src/shared/test/setupTests.ts", "tests/**/*"],
      thresholds: {
        lines: 100,
        statements: 100,
        functions: 100,
        branches: 100,
      },
    },
  },
});

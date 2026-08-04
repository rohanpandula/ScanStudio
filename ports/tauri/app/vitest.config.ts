import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: [
      "tests/**/*.test.ts",
      "src/**/__tests__/**/*.test.{ts,tsx}",
      "src/**/*.test.{ts,tsx}",
    ],
    environment: "node",
    testTimeout: 30000,
    // Real-engine integration tests (tests/integration/*) spawn the simulator
    // binary at timeScale 0.01 -- a full 36-frame job completes in ~300ms and
    // asserts on mid-job frame states (cooperative stop, fault-injection
    // retry). Under file-level parallelism those sub-second observation
    // windows are starved by concurrent test files and the assertions flake.
    // Running test files sequentially gives each engine job full CPU and
    // makes the integration suite deterministic.
    fileParallelism: false,
  },
});

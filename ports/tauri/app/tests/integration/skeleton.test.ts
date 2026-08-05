import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { describe, expect, it } from "vitest";

interface WireLine {
  id?: number;
  result?: unknown;
  error?: { code: string; message: string; recoverable: boolean };
  event?: string;
  payload?: unknown;
}

describe("skeleton integration against the real engine binary", () => {
  it("drives hello -> list -> connect -> loadMedia -> status -> shutdown", async () => {
    const enginePath = process.env.SCANSTUDIO_ENGINE_PATH;
    if (!enginePath) {
      console.log(
        "[skeleton.test] SCANSTUDIO_ENGINE_PATH not set - skipping integration test",
      );
      return;
    }

    const child = spawn(enginePath, [], { stdio: ["pipe", "pipe", "pipe"] });
    let nextId = 1;
    const pending = new Map<number, (line: WireLine) => void>();
    const events: WireLine[] = [];

    const rl = createInterface({ input: child.stdout! });
    rl.on("line", (raw) => {
      let line: WireLine;
      try {
        line = JSON.parse(raw) as WireLine;
      } catch {
        return;
      }
      if (typeof line.id === "number" && pending.has(line.id)) {
        const resolve = pending.get(line.id)!;
        pending.delete(line.id);
        resolve(line);
      } else if (line.event !== undefined) {
        events.push(line);
      }
    });

    const request = (method: string, params: unknown): Promise<WireLine> =>
      new Promise<WireLine>((resolve, reject) => {
        const id = nextId++;
        pending.set(id, resolve);
        child.stdin!.write(JSON.stringify({ id, method, params }) + "\n", (err) => {
          if (err) {
            reject(err);
          }
        });
      });

    try {
      const hello = await request("engine.hello", {
        clientName: "skeleton-test",
        protocolVersion: 1,
      });
      const helloResult = hello.result as {
        engineName: string;
        protocolVersion: number;
        capabilities: string[];
      };
      expect(helloResult.engineName).toBe("scanstudio-engine");
      expect(helloResult.protocolVersion).toBe(1);
      expect(helloResult.capabilities).toContain("simulated-ls5000");

      const list = await request("scanner.list", {});
      const listResult = list.result as { devices: { deviceId: string }[] };
      expect(listResult.devices.length).toBe(1);
      expect(listResult.devices[0].deviceId).toBe("sim-ls5000-0");

      const connect = await request("scanner.connect", {
        deviceId: "sim-ls5000-0",
        options: { timeScale: 0.01 },
      });
      const connectResult = connect.result as { status: { connected: boolean } };
      expect(connectResult.status.connected).toBe(true);

      const load = await request("sim.loadMedia", { carrier: "roll36" });
      const loadResult = load.result as { mediaLoaded: boolean; frameCount: number };
      expect(loadResult.mediaLoaded).toBe(true);
      expect(loadResult.frameCount).toBe(36);

      const status = await request("scanner.status", {});
      const statusResult = status.result as {
        connected: boolean;
        mediaLoaded: boolean;
        frameCount: number;
      };
      expect(statusResult.connected).toBe(true);
      expect(statusResult.mediaLoaded).toBe(true);
      expect(statusResult.frameCount).toBe(36);

      expect(events.some((e) => e.event === "scanner.status")).toBe(true);

      const shutdown = await request("engine.shutdown", {});
      expect(shutdown.result).toEqual({});

      const exitCode = await new Promise<number | null>((resolve) => {
        if (child.exitCode !== null) {
          resolve(child.exitCode);
          return;
        }
        const timer = setTimeout(() => resolve(null), 5000);
        child.on("exit", (code) => {
          clearTimeout(timer);
          resolve(code);
        });
      });
      expect(exitCode).toBe(0);
    } finally {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGKILL");
      }
    }
  });
});

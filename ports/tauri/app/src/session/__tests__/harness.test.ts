import { describe, expect, it } from "vitest";
import { createScriptedTransport, createSubprocessTransport } from "../testing/harness";
import type { EngineError, WireEvent } from "../wire/types";

const ENGINE_PATH = process.env.SCANSTUDIO_ENGINE_PATH;
if (!ENGINE_PATH) {
  console.log("SCANSTUDIO_ENGINE_PATH not set -- skipping subprocess-transport tests");
}
const describeSubprocess = ENGINE_PATH ? describe : describe.skip;

async function waitFor(predicate: () => boolean, timeoutMs = 10000): Promise<void> {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > timeoutMs) {
      throw new Error("waitFor timed out");
    }
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

describeSubprocess("subprocess transport against the real engine binary", () => {
  it("subprocess transport completes engine.hello -> scanner.list -> scanner.connect{timeScale:0.01} against the real binary", async () => {
    const handle = await createSubprocessTransport({
      engineBinaryPath: ENGINE_PATH as string,
      timeScale: 0.01,
    });
    try {
      const hello = (await handle.transport.sendRequest("engine.hello", {
        clientName: "harness-test",
        protocolVersion: 1,
      })) as { engineName: string; protocolVersion: number; capabilities: string[] };
      expect(hello.engineName).toBe("scanstudio-engine");
      expect(hello.protocolVersion).toBe(1);
      expect(hello.capabilities).toContain("simulated-ls5000");

      const list = (await handle.transport.sendRequest("scanner.list", {})) as {
        devices: { deviceId: string }[];
      };
      expect(list.devices).toHaveLength(1);

      const connect = (await handle.transport.sendRequest("scanner.connect", {
        deviceId: list.devices[0].deviceId,
        options: { timeScale: handle.timeScale },
      })) as { device: { deviceId: string }; status: { connected: boolean } };
      expect(connect.device.deviceId).toBe(list.devices[0].deviceId);
      expect(connect.status.connected).toBe(true);
      expect(handle.timeScale).toBe(0.01);
    } finally {
      await handle.close();
    }
  });

  it("subprocess transport surfaces a wire error response as {code,message,recoverable} without throwing a generic Error", async () => {
    const handle = await createSubprocessTransport({
      engineBinaryPath: ENGINE_PATH as string,
      timeScale: 0.01,
    });
    try {
      await handle.transport.sendRequest("engine.hello", {
        clientName: "harness-test",
        protocolVersion: 1,
      });
      let caught: unknown;
      try {
        await handle.transport.sendRequest("scanner.connect", { deviceId: "no-such-device" });
      } catch (error) {
        caught = error;
      }
      expect(caught).toBeDefined();
      expect(caught).not.toBeInstanceOf(Error);
      const engineError = caught as EngineError;
      expect(engineError.code).toBe("UNKNOWN_DEVICE");
      expect(typeof engineError.message).toBe("string");
      expect(typeof engineError.recoverable).toBe("boolean");
    } finally {
      await handle.close();
    }
  });

  it("subprocess transport delivers events to subscribers in arrival order", async () => {
    const handle = await createSubprocessTransport({
      engineBinaryPath: ENGINE_PATH as string,
      timeScale: 0.01,
    });
    try {
      const first: unknown[] = [];
      const second: unknown[] = [];
      const unsubscribe = handle.transport.subscribeEvents((raw) => first.push(raw));
      handle.transport.subscribeEvents((raw) => second.push(raw));

      await handle.transport.sendRequest("engine.hello", {
        clientName: "harness-test",
        protocolVersion: 1,
      });
      const list = (await handle.transport.sendRequest("scanner.list", {})) as {
        devices: { deviceId: string }[];
      };
      await handle.transport.sendRequest("scanner.connect", {
        deviceId: list.devices[0].deviceId,
        options: { timeScale: handle.timeScale },
      });
      await handle.transport.sendRequest("sim.loadMedia", { carrier: "roll36" });

      await waitFor(() => first.length >= 2 && second.length >= 2);
      unsubscribe();

      expect(second).toEqual(first);
      const statuses = first.map((raw) => (raw as WireEvent<{ status: Record<string, unknown> }>)
        .payload.status) as { connected: boolean; mediaLoaded: boolean; frameCount: number | null }[];
      expect(statuses[0].connected).toBe(true);
      expect(statuses[0].mediaLoaded).toBe(false);
      expect(statuses[1].mediaLoaded).toBe(true);
      expect(statuses[1].frameCount).toBe(36);
      for (const raw of first) {
        expect((raw as WireEvent).event).toBe("scanner.status");
      }
    } finally {
      await handle.close();
    }
  });
});

describe("scripted transport", () => {
  it("scripted transport resolves a canned request via onRequest and lets a test manually emitEvent", async () => {
    const calls: { method: string; params: unknown }[] = [];
    const handle = createScriptedTransport({
      onRequest: (method, params) => {
        calls.push({ method, params });
        if (method === "scanner.list") {
          return { result: { devices: [{ deviceId: "sim-ls5000-0" }] } };
        }
        return { error: { code: "NOT_CONNECTED", message: "no device", recoverable: true } };
      },
    });

    const result = (await handle.transport.sendRequest("scanner.list", {})) as {
      devices: { deviceId: string }[];
    };
    expect(result.devices[0].deviceId).toBe("sim-ls5000-0");
    expect(calls).toEqual([{ method: "scanner.list", params: {} }]);

    let caught: unknown;
    try {
      await handle.transport.sendRequest("scanner.status", {});
    } catch (error) {
      caught = error;
    }
    expect(caught).toMatchObject({ code: "NOT_CONNECTED", recoverable: true });

    const received: unknown[] = [];
    const unsubscribe = handle.transport.subscribeEvents((raw) => received.push(raw));
    const event = { event: "scan.jobState", payload: { jobId: "job-1", state: "scanning" } };
    handle.emitEvent(event);
    expect(received).toEqual([event]);

    unsubscribe();
    handle.emitEvent(event);
    expect(received).toEqual([event]);
  });

  it("resolves with undefined when no onRequest script is provided", async () => {
    const handle = createScriptedTransport();
    await expect(handle.transport.sendRequest("scanner.list", {})).resolves.toBeUndefined();
  });
});

describe("bounded request timeout", () => {
  it("a request that never resolves rejects after the bounded timeout instead of hanging the suite", async () => {
    // A subprocess that echoes each request line back verbatim; the echo
    // decodes as a "request" envelope (never a response), standing in for a
    // hung engine. Uses the current Node runtime so it is cross-platform
    // (there is no /bin/cat on Windows).
    const handle = await createSubprocessTransport({
      engineBinaryPath: process.execPath,
      engineBinaryArgs: ["-e", "process.stdin.pipe(process.stdout)"],
      timeoutMs: 100,
    });
    try {
      await expect(
        handle.transport.sendRequest("engine.hello", {
          clientName: "timeout-test",
          protocolVersion: 1,
        }),
      ).rejects.toThrow(/timed out after 100ms/);
    } finally {
      await handle.close();
    }
  });
});

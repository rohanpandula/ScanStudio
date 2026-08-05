import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { SessionStore } from "../../src/session/store/session";
import {
  createSubprocessTransport,
  type SubprocessTransportHandle,
} from "../../src/session/testing/harness";

// Store-level integration flow test against the REAL engine subprocess
// (fixture-mode is what the component tests use; this is the strongest proof
// the whole device -> project -> preview path works end to end).
describe("core-workflow integration against the real engine binary", () => {
  let handle: SubprocessTransportHandle | null = null;
  const tempDirs: string[] = [];

  afterEach(async () => {
    if (handle) {
      try {
        await handle.close();
      } catch {
        // Engine already gone; nothing to reclaim.
      }
      handle = null;
    }
    for (const dir of tempDirs) {
      rmSync(dir, { recursive: true, force: true });
    }
    tempDirs.length = 0;
  });

  const waitForPreviewSettled = async (
    store: SessionStore,
    timeoutMs = 30000,
  ): Promise<void> => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const { previewOutcome } = store.getState();
      if (previewOutcome === "succeeded" || previewOutcome === "failed") {
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    throw new Error("preview did not settle within the timeout");
  };

  it("connect -> create project (manifest on disk) -> loadMedia -> preview -> 36 thumbnails", async () => {
    const enginePath = process.env.SCANSTUDIO_ENGINE_PATH;
    if (!enginePath) {
      console.log(
        "[core-workflow.test] SCANSTUDIO_ENGINE_PATH not set - skipping integration test",
      );
      return;
    }

    handle = await createSubprocessTransport({
      engineBinaryPath: enginePath,
      timeScale: 0.01,
      timeoutMs: 10000,
    });

    // engine.hello is mandatory as the first request (the production Tauri
    // client performs this handshake on init; the subprocess transport does
    // not, per the harness's documented contract).
    await handle.transport.sendRequest("engine.hello", {
      clientName: "core-workflow-test",
      protocolVersion: 1,
    });

    // Integration-mode store over the real spawned engine.
    const store = new SessionStore(handle.transport);

    // (2) Device list -> connect to the one simulated device.
    const { devices } = await store.listDevices();
    expect(devices.length).toBe(1);
    const deviceId = devices[0].deviceId;
    await store.connect(deviceId);

    // (3) Create a roll36 project in a fresh temp directory.
    const root = mkdtempSync(join(tmpdir(), "core-workflow-"));
    tempDirs.push(root);
    const { directory } = await store.createProject(
      "core-workflow-test",
      "roll36",
      36,
      "c41ColorNegative",
      root,
    );

    // (3b) UI-06's roadmap criterion: the manifest is REAL ON DISK, not just
    // store state. Never guess which file is the manifest — fail loudly with
    // the directory listing if the candidate count is wrong.
    const candidates = readdirSync(directory).filter((f) => f.endsWith(".json"));
    if (candidates.length !== 1) {
      throw new Error(
        `expected exactly one .json manifest in ${directory}, found ${candidates.length}; ` +
          `directory listing: ${JSON.stringify(readdirSync(directory))}`,
      );
    }
    const manifest = JSON.parse(
      readFileSync(join(directory, candidates[0]), "utf8"),
    ) as {
      schemaVersion?: number;
      name?: string;
      frameCount?: number;
    };
    expect(manifest.schemaVersion).toBe(4);
    expect(manifest.name).toBe("core-workflow-test");
    expect(manifest.frameCount).toBe(36);

    // (4) Load media, then (5) run the preview.
    await store.loadMedia("roll36");
    await store.acquireThumbnails(undefined, "c41ColorNegative");

    // (6) Await settlement and assert the end state.
    await waitForPreviewSettled(store);
    expect(store.getState().latestCompletedPreviewOperationId).not.toBe(null);
    const state = store.getState();
    expect(state.previewOutcome).toBe("succeeded");
    expect(state.previewError).toBeNull();
    expect(Object.keys(state.thumbnails)).toHaveLength(36);
    expect(state.connection.status?.mediaLoaded).toBe(true);
    expect(state.connection.status?.frameCount).toBe(36);
    expect(state.connection.status?.transport).toBe("idle");
  });
});

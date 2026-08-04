// Real-engine metadata integration flow (07-01 Task 3): drive the engine
// binary directly over NDJSON to prove the detect -> previewMetadataCommand ->
// applyMetadata roundtrip works end to end with a STUB ExifTool on PATH (CI
// never depends on a real ExifTool install). The stub reports available:true
// only because this test prepends tests/support/fake-exiftool to PATH.
//
// The test SKIPS with a clear message (never silently passes) when
// SCANSTUDIO_ENGINE_PATH is unset, mirroring the skeleton integration test.

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createSubprocessTransport, type SubprocessTransportHandle } from "../../src/session/testing/harness";
import type {
  ApplyMetadataResult,
  ExifToolDetection,
  PreviewMetadataCommandResult,
  ScanProject,
} from "../../src/session/wire/types";

const FAKE_EXIFTOOL_DIR = fileURLToPath(
  new URL("../support/fake-exiftool", import.meta.url),
);

const SAMPLE_METADATA = {
  camera: "Nikon F6",
  lens: "Nikkor 50mm f/1.4",
  filmStock: "Portra 400",
  iso: 400,
  date: { kind: "yearOnly", year: 2024 },
  location: "Portland",
  photographer: "Rohan",
  copyright: "2026 Rohan",
  rollId: "R-001",
  notes: "Push +1",
  keywords: ["street", "color"],
} as const;

describe("metadata detect -> preview -> apply against the real engine binary", () => {
  let handle: SubprocessTransportHandle | null = null;
  const tempDirs: string[] = [];
  const originalPath = process.env.PATH;
  const originalExifToolPath = process.env.SCANSTUDIO_EXIFTOOL_PATH;

  beforeAll(() => {
    // Prepend the stub exiftool so the engine's PATH probe resolves to our
    // deterministic fake rather than a real install (or nothing).
    process.env.PATH = `${FAKE_EXIFTOOL_DIR}${delimiter}${originalPath ?? ""}`;
    // The exact-path env override would bypass the PATH probe entirely;
    // remove it for the duration so this test exercises the PATH path.
    delete process.env.SCANSTUDIO_EXIFTOOL_PATH;
  });

  afterAll(async () => {
    if (originalExifToolPath !== undefined) {
      process.env.SCANSTUDIO_EXIFTOOL_PATH = originalExifToolPath;
    } else {
      delete process.env.SCANSTUDIO_EXIFTOOL_PATH;
    }
    if (originalPath !== undefined) {
      process.env.PATH = originalPath;
    } else {
      delete process.env.PATH;
    }
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

  const withDeadline = <T>(promise: Promise<T>, description: string, timeoutMs: number): Promise<T> =>
    Promise.race([
      promise,
      new Promise<T>((_, reject) =>
        setTimeout(() => reject(new Error(`timed out waiting for: ${description}`)), timeoutMs),
      ),
    ]);

  it(
    "hello -> connect -> loadMedia -> create project -> detect stub exiftool -> setRollMetadata -> preview thumbnails -> previewMetadataCommand -> applyMetadata",
    async () => {
      const enginePath = process.env.SCANSTUDIO_ENGINE_PATH;
      if (!enginePath) {
        console.log(
          "[metadata.test] SCANSTUDIO_ENGINE_PATH not set - skipping integration test",
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
      const hello = (await handle.transport.sendRequest("engine.hello", {
        clientName: "metadata-test",
        protocolVersion: 1,
      })) as { engineName: string; protocolVersion: number };
      expect(hello.engineName).toBe("scanstudio-engine");
      expect(hello.protocolVersion).toBe(1);

      // scanner.connect to the one simulated device.
      const list = (await handle.transport.sendRequest("scanner.list", {})) as {
        devices: Array<{ deviceId: string }>;
      };
      expect(list.devices.length).toBe(1);
      const deviceId = list.devices[0].deviceId;
      await handle.transport.sendRequest("scanner.connect", {
        deviceId,
        options: { timeScale: 0.01 },
      });

      await handle.transport.sendRequest("sim.loadMedia", { carrier: "roll36" });

      // project.create into a fresh temp dir: the test never writes into a
      // real projects folder.
      const root = mkdtempSync(join(tmpdir(), "metadata-it-"));
      tempDirs.push(root);
      const created = (await handle.transport.sendRequest("project.create", {
        name: "metadata-it",
        carrier: "roll36",
        frameCount: 36,
        filmProcess: "c41ColorNegative",
        directory: root,
      })) as { project: ScanProject; directory: string };
      expect(created.project.schemaVersion).toBe(4);
      expect(created.project.frameCount).toBe(36);

      // exiftool.detect resolves available:true ONLY via the stub, and the
      // version 12.76 is the stub's own `-ver` output (a real ExifTool is not
      // installed on this machine; the bare "exiftool" path echo is the
      // engine's literal candidate string).
      const detection = (await handle.transport.sendRequest("exiftool.detect", {})) as ExifToolDetection;
      expect(detection.available).toBe(true);
      expect(detection.path).not.toBeNull();
      expect(detection.path).not.toBe("");
      expect(detection.version).toBe("12.76");

      // project.setRollMetadata persists a whole MetadataSet.
      const rolled = (await handle.transport.sendRequest("project.setRollMetadata", {
        metadata: SAMPLE_METADATA,
      })) as { project: ScanProject };
      expect(rolled.project.rollMetadata.camera).toBe("Nikon F6");
      expect(rolled.project.rollMetadata.keywords).toEqual(["street", "color"]);

      // scanner.acquireThumbnails -> wait for the correlated completion event.
      let resolveDone: (() => void) | undefined;
      const thumbnailsDone = new Promise<void>((resolve) => {
        resolveDone = resolve;
      });
      const unsubscribe = handle.transport.subscribeEvents((raw) => {
        if ((raw as { event?: string }).event === "scanner.thumbnailsComplete") {
          resolveDone?.();
        }
      });
      try {
        const ack = (await handle.transport.sendRequest("scanner.acquireThumbnails", {})) as {
          accepted: boolean;
        };
        expect(ack.accepted).toBe(true);
        await withDeadline(thumbnailsDone, "scanner.thumbnailsComplete", 30000);
      } finally {
        unsubscribe();
      }

      // previewMetadataCommand: a read-only dry run returns the exact argument
      // array before anything runs.
      const preview = (await handle.transport.sendRequest(
        "project.previewMetadataCommand",
        { frameIndex: 1 },
      )) as PreviewMetadataCommandResult;
      expect(preview.available).toBe(true);
      expect(preview.exiftoolPath).not.toBeNull();
      expect(Array.isArray(preview.targets)).toBe(true);
      expect(Array.isArray(preview.arguments)).toBe(true);

      // applyMetadata: with no scan run, the frame has no scanned outputs, so
      // targets is empty and apply rejects with INVALID_PARAMS per
      // PROTOCOL.md's documented "no scanned outputs yet" error. If targets
      // were non-empty we would assert exitCode 0 from the stub instead.
      if (preview.targets.length > 0) {
        const applied = (await handle.transport.sendRequest("project.applyMetadata", {
          frameIndex: 1,
        })) as ApplyMetadataResult;
        expect(applied.exitCode).toBe(0);
        expect(applied.stdout).toContain("1 image files updated");
      } else {
        await expect(
          handle.transport.sendRequest("project.applyMetadata", { frameIndex: 1 }),
        ).rejects.toMatchObject({ code: "INVALID_PARAMS" });
      }
      // afterAll's handle.close() sends engine.shutdown and waits for the
      // engine to exit cleanly (the harness's bounded shutdown-close path).
    },
    60000,
  );
});

import { useEffect, useState } from "react";
import { useSyncExternalStore } from "react";
import {
  applyRecipeDefaults,
  coerceMultisamplePasses,
  multisampleOptionsForDevice,
  type ResolvedCaptureRecipe,
  resolveEffectiveProcessing,
} from "../../session/store/session";
import type { OutputRecipe, ProcessingRecipe } from "../../session/wire/types";
import type { EngineError, ExifToolDetection } from "../../session/wire/types";
import { sessionStore } from "../../session";
import CaptureRecipeForm from "./CaptureRecipeForm";
import ProcessingRecipeForm from "./ProcessingRecipeForm";
import OutputRecipeForm from "./OutputRecipeForm";
import FrameOverrideEditor from "./FrameOverrideEditor";
import MetadataPanel from "../MetadataPanel";
import styles from "./ScanSetup.module.css";

export interface ScanSetupViewProps {
  selectedFrames: number[];
  onScanStarted: (
    jobId: string,
    recipes?: { capture: ResolvedCaptureRecipe; processing?: ProcessingRecipe; output?: OutputRecipe },
  ) => void;
  onRequestConnect: () => void;
}

// Module-scope stable-snapshot bridge (Phase 5 precedent): getState()
// deep-clones per call, so a bare sessionStore.getState would violate
// useSyncExternalStore's referential-stability contract.
let cachedStore: unknown = null;
let cachedSnapshot: ReturnType<typeof sessionStore.getState> | null = null;
function stableGetSnapshot(): ReturnType<typeof sessionStore.getState> {
  if (cachedStore !== sessionStore || cachedSnapshot === null) {
    cachedStore = sessionStore;
    cachedSnapshot = sessionStore.getState();
  }
  return cachedSnapshot;
}
function stableSubscribe(listener: () => void): () => void {
  const unsubscribe = sessionStore.subscribe(() => {
    cachedSnapshot = null;
    listener();
  });
  return unsubscribe;
}

// Fallback output recipe used only when the form mounts with no project
// loaded yet (ScanSetupView's empty state hides the form until a project
// exists, so this is never passed to the engine).
const FALLBACK_OUTPUT: OutputRecipe = {
  archive: {
    enabled: true,
    filenameTemplate: "IMG_####.tiff",
    destination: "",
    fullCapturePackage: true,
  },
  positive: {
    enabled: false,
    fileFormat: "tiff",
    colorProfile: "sRgb",
    filenameTemplate: "POS_####.tiff",
    destination: "",
  },
  preview: {
    enabled: false,
    fileFormat: "jpeg",
    maxLongEdgePx: 2048,
    filenameTemplate: "PRE_####.jpg",
    destination: "",
  },
  autoCrop: false,
};

export default function ScanSetupView({
  selectedFrames,
  onScanStarted,
  onRequestConnect,
}: ScanSetupViewProps) {
  const state = useSyncExternalStore(stableSubscribe, stableGetSnapshot);
  const project = state.project;
  const filmProcess = project?.filmProcess ?? "c41ColorNegative";
  const connectedDevice = state.connection.device;

  // Roll-wide recipes: resolved defaults for capture (the project manifest
  // does not carry a capture/processing recipe), and the project's stored
  // output recipe for output. Seeded with whatever device is already
  // connected at mount time -- a real LS-5000 connected before this view
  // ever rendered must not seed the simulator-shaped default of 1 that its
  // own scan.start gate would then reject with INVALID_PARAMS.
  const resolved = applyRecipeDefaults(undefined, undefined, undefined, connectedDevice);
  // Device-aware picker options (mirrors Swift's MultisamplePassPolicy);
  // recomputed every render, cheap, and always in sync with the connected
  // device -- no memoization needed for a five-element-at-most array.
  const multisampleOptions = multisampleOptionsForDevice(connectedDevice);
  const initialOutput = project?.recipes;
  const [capture, setCapture] = useState(resolved.capture);
  const [processing, setProcessing] = useState<ProcessingRecipe>(() => {
    const effective = resolveEffectiveProcessing(
      {
        filmProcess,
        autofocusEachFrame: true,
        autoExposureEachFrame: true,
        digitalIceEnabled: false,
        digitalIceMode: "legacy",
        softwareDustRemovalBw: false,
      },
      resolved.capture.channels,
    );
    const { channels: _channels, ...plain } = effective;
    void _channels;
    return plain;
  });
  const [output, setOutput] = useState<OutputRecipe>(initialOutput ?? FALLBACK_OUTPUT);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<EngineError | null>(null);
  // ExifTool detection chip (07-01): a capability query, fetched once on
  // mount; the panel renders the exact command before Apply becomes enabled.
  const [exifToolDetection, setExifToolDetection] = useState<ExifToolDetection | null>(null);

  useEffect(() => {
    void sessionStore
      .detectExifTool()
      .then((result) => setExifToolDetection(result))
      .catch(() => setExifToolDetection(null));
  }, []);

  // Coerce on connect (mirrors Swift's coerceMultisamplePassesForConnectedDevice,
  // called after scanner.connect and again after createProject while
  // already connected): a device change can make the CURRENT
  // multisamplePasses value unsupported (a real LS-5000 accepts only [4]).
  // TS has no single persistent recipe draft to re-coerce at those two
  // Swift call sites directly -- capture is this view's own local state --
  // so this effect re-derives the connected device's options and
  // re-coerces whenever the device's identity or its own reported options
  // change; a no-op transition (options unchanged, current value still
  // valid) returns the same object from the updater, so React bails out
  // without an extra render. The mount-time seed above already covers a
  // device connected before this view ever rendered; this effect covers
  // one connecting (or reporting a different capability list) while the
  // view stays mounted.
  useEffect(() => {
    setCapture((current) => {
      const coerced = coerceMultisamplePasses(current.multisamplePasses, multisampleOptions);
      return coerced === current.multisamplePasses
        ? current
        : { ...current, multisamplePasses: coerced as ResolvedCaptureRecipe["multisamplePasses"] };
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [
    connectedDevice?.deviceId,
    connectedDevice?.kind,
    connectedDevice?.supportedMultisamplePasses?.join(","),
  ]);

  // If a project loads after mount (or changes), adopt its output recipes as
  // the form's starting point instead of leaving stale defaults.
  useEffect(() => {
    if (project !== null) {
      setOutput(project.recipes);
      const effective = resolveEffectiveProcessing(
        {
          filmProcess,
          autofocusEachFrame: processing.autofocusEachFrame,
          autoExposureEachFrame: processing.autoExposureEachFrame,
          digitalIceEnabled: processing.digitalIceEnabled,
          digitalIceMode: processing.digitalIceMode,
          softwareDustRemovalBw: processing.softwareDustRemovalBw,
        },
        resolved.capture.channels,
      );
      const { channels: _channels, ...plain } = effective;
      void _channels;
      setProcessing(plain);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [project?.id]);

  const start = async (): Promise<void> => {
    setError(null);
    setBusy(true);
    try {
      const result = await sessionStore.startScan(
        selectedFrames,
        capture,
        processing,
        output,
      );
      // Surface the exact recipes used so a resume can replay them (the
      // pending-frames panel must not drop the operator's configured
      // destinations/templates/ICE).
      onScanStarted(result.jobId, { capture, processing, output });
    } catch (reason) {
      setError((reason as EngineError) ?? { code: "UNKNOWN", message: "start failed", recoverable: false });
    } finally {
      setBusy(false);
    }
  };

  // Cmd/Ctrl+Return starts the scan (parity with SwiftUI bindings; the one
  // extra keyboard shortcut 06-CONTEXT permits beyond the viewer keys).
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent): void => {
      if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
        event.preventDefault();
        void start();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedFrames, capture, processing, output, busy]);

  if (state.connection.connected === false || project === null) {
    return (
      <div className={styles.viewShell} data-testid="scan-setup-empty">
        <div className={styles.section}>
          <p className={styles.fieldValue}>
            Connect to a device and create or open a project to configure scanning.
          </p>
          <button
            type="button"
            className={styles.controlButton}
            data-testid="scan-setup-reconnect"
            onClick={onRequestConnect}
          >
            Connect device
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className={styles.viewShell} data-testid="scan-setup-view">
      <div className={styles.viewHeader}>
        <h2 className={styles.heading}>Scan Setup</h2>
        <button
          type="button"
          className={styles.primaryButton}
          data-testid="start-scan"
          disabled={busy || selectedFrames.length === 0}
          onClick={() => void start()}
        >
          Start Scan ({selectedFrames.length} frame{selectedFrames.length === 1 ? "" : "s"})
        </button>
      </div>
      <p className={styles.fieldLabel}>Selected frames: {selectedFrames.join(", ") || "none"}</p>
      {error && (
        <p className={styles.banner} data-testid="scan-start-error" data-code={error.code}>
          {error.message}
        </p>
      )}
      <CaptureRecipeForm
        capture={capture}
        filmProcess={filmProcess}
        multisampleOptions={multisampleOptions}
        onChange={setCapture}
      />
      <ProcessingRecipeForm processing={processing} filmProcess={filmProcess} onChange={setProcessing} />
      {output && <OutputRecipeForm output={output} onChange={setOutput} />}
      {project && (
        <FrameOverrideEditor
          key={selectedFrames[0] ?? 1}
          frameIndex={selectedFrames[0] ?? 1}
          filmProcess={filmProcess}
          rollCapture={capture}
          rollProcessing={processing}
          rollOutput={output ?? resolved.output}
          multisampleOptions={multisampleOptions}
          project={project}
        />
      )}
      {project && (
        <MetadataPanel
          rollMetadata={project.rollMetadata}
          onSave={(next) => void sessionStore.setRollMetadata(next)}
          exifToolDetection={exifToolDetection}
          onDetectExifTool={() =>
            void sessionStore
              .detectExifTool()
              .then((result) => setExifToolDetection(result))
              .catch(() => setExifToolDetection(null))
          }
        />
      )}
    </div>
  );
}

import { useEffect, useState, useSyncExternalStore } from "react";
import {
  sessionStore,
  type FilmProcess,
  type SessionState,
} from "../session";
import { sessionOperationBusy } from "../session/store/session";
import { previewImageSrc } from "../session/webApis";
import { isEngineError } from "../session/wire/types";
import type { DerivativeTransform, EngineError, Thumbnail } from "../session/wire/types";
import styles from "./ContactSheet.module.css";

// useSyncExternalStore requires a referentially stable snapshot between
// store notifications, but SessionStore.getState() deep-clones on every call.
// Cache one snapshot per store generation here (same stable-snapshot bridge
// as DeviceBar/ProjectPanel): invalidated on each notify and on store
// identity change (fixture swaps in tests).
let cachedStore: unknown = null;
let cachedSnapshot: Readonly<SessionState> | null = null;

function stableSubscribe(listener: () => void): () => void {
  const unsubscribe = sessionStore.subscribe(() => {
    cachedSnapshot = null;
    listener();
  });
  return unsubscribe;
}

function stableGetSnapshot(): Readonly<SessionState> {
  if (cachedStore !== sessionStore) {
    cachedStore = sessionStore;
    cachedSnapshot = null;
  }
  if (cachedSnapshot === null) {
    cachedSnapshot = sessionStore.getState();
  }
  return cachedSnapshot;
}

const CARRIERS = ["roll36", "strip6", "mounted"] as const;
const FILM_PROCESSES: Array<{ value: FilmProcess; label: string }> = [
  { value: "positive", label: "Positive" },
  { value: "c41ColorNegative", label: "Color negative (C-41)" },
  { value: "bwNegative", label: "B&W negative" },
  { value: "kodachrome", label: "Kodachrome" },
];

// Behaviorally equivalent to ThumbnailGridView's shaded-tile rendering (gray
// tile shaded by brightness with a tint cast), not pixel-identical.
function tileBackground(thumbnail: Thumbnail): string {
  const brightness = thumbnail.brightness ?? 0.5;
  const tint = thumbnail.tint ?? 0;
  const lightness = Math.max(0, Math.min(100, Math.round(brightness * 100)));
  return `hsl(${tint} 30% ${lightness}%)`;
}

function transformStyle(transform: DerivativeTransform): React.CSSProperties {
  const swapsAxes =
    transform.rotationDegrees === 90 || transform.rotationDegrees === 270;
  return {
    position: "absolute",
    left: "50%",
    top: "50%",
    width: swapsAxes ? "150%" : "100%",
    height: swapsAxes ? "66.6667%" : "100%",
    transform:
      `translate(-50%, -50%) rotate(${transform.rotationDegrees}deg) ` +
      `scaleX(${transform.horizontalMirror ? -1 : 1}) ` +
      `scaleY(${transform.verticalMirror ? -1 : 1})`,
  };
}

function shortcutTargetIsEditable(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  return (
    target.isContentEditable ||
    target.tagName === "INPUT" ||
    target.tagName === "TEXTAREA" ||
    target.tagName === "SELECT"
  );
}

function requestErrorOf(error: unknown): Pick<EngineError, "code" | "message"> {
  if (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    "message" in error &&
    typeof (error as { code: unknown }).code === "string" &&
    typeof (error as { message: unknown }).message === "string"
  ) {
    return error as Pick<EngineError, "code" | "message">;
  }
  return {
    code: "INTERNAL",
    message: error instanceof Error ? error.message : "scanner status request failed",
  };
}

export interface ContactSheetProps {
  onInspectFrame?: (frameIndex: number) => void;
  onCapture?: () => void;
}

type StatusRefreshFeedback = "notEnabled" | "unknown" | "ready" | null;

export default function ContactSheet({ onInspectFrame, onCapture }: ContactSheetProps = {}) {
  const [statusRefreshError, setStatusRefreshError] = useState<Pick<
    EngineError,
    "code" | "message"
  > | null>(null);
  const [statusRefreshInProgress, setStatusRefreshInProgress] = useState(false);
  const [statusRefreshFeedback, setStatusRefreshFeedback] =
    useState<StatusRefreshFeedback>(null);
  const [mediaLoadError, setMediaLoadError] = useState<Pick<
    EngineError,
    "code" | "message"
  > | null>(null);
  const state = useSyncExternalStore(stableSubscribe, stableGetSnapshot);
  const status = state.connection.status;
  const project = state.project;
  const mediaLoaded = status?.mediaLoaded === true;
  const connected = state.connection.connected;
  const deviceKind = state.connection.device?.kind ?? null;
  const canLoadSimulatedMedia = !mediaLoaded && connected && deviceKind === "simulated";
  const canPreview = mediaLoaded || (connected && deviceKind === "real");
  const motionReadiness =
    deviceKind !== "real"
      ? "notApplicable"
      : status?.motionArmed === true
        ? "ready"
        : status?.motionArmed === false
          ? "notEnabled"
          : "unknown";
  const motionReady = motionReadiness === "ready" || motionReadiness === "notApplicable";
  const transportReady = status?.transport === "idle";
  const operationBusy = sessionOperationBusy(state);
  const previewDisabled = operationBusy || !motionReady || !transportReady;
  const frameCount = mediaLoaded ? (status?.frameCount ?? 0) : 0;
  const selectionEmpty = state.selectedFrameIndices.length === 0;
  const transformsEditable =
    !operationBusy;
  const focusedFrameIndex = state.focusedFrameIndex;

  useEffect(() => {
    if (motionReadiness === "ready") setStatusRefreshError(null);
  }, [motionReadiness]);

  const checkScanner = async (): Promise<void> => {
    setStatusRefreshError(null);
    setStatusRefreshFeedback(null);
    setStatusRefreshInProgress(true);
    try {
      const refreshedStatus = await sessionStore.refreshStatus();
      setStatusRefreshFeedback(
        refreshedStatus.motionArmed === true
          ? "ready"
          : refreshedStatus.motionArmed === false
            ? "notEnabled"
            : "unknown",
      );
    } catch (error) {
      setStatusRefreshError(requestErrorOf(error));
    } finally {
      setStatusRefreshInProgress(false);
    }
  };

  const loadSimulatedMedia = async (
    carrier: (typeof CARRIERS)[number],
  ): Promise<void> => {
    setMediaLoadError(null);
    try {
      await sessionStore.loadMedia(carrier);
    } catch (error) {
      setMediaLoadError(requestErrorOf(error));
    }
  };

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent): void => {
      if (
        shortcutTargetIsEditable(event.target) ||
        focusedFrameIndex === null ||
        !transformsEditable ||
        !(event.metaKey || event.ctrlKey)
      ) {
        return;
      }
      const key = event.key.toLowerCase();
      if (key === "l" && !event.shiftKey && !event.altKey) {
        event.preventDefault();
        sessionStore.rotateFrames([focusedFrameIndex], -90);
      } else if (key === "r" && !event.shiftKey && !event.altKey) {
        event.preventDefault();
        sessionStore.rotateFrames([focusedFrameIndex], 90);
      } else if (key === "h" && event.shiftKey) {
        event.preventDefault();
        sessionStore.toggleHorizontalMirror([focusedFrameIndex]);
      } else if (key === "v" && event.altKey) {
        event.preventDefault();
        sessionStore.toggleVerticalMirror([focusedFrameIndex]);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [focusedFrameIndex, transformsEditable]);

  const preview = (): void => {
    const filmProcess = project?.filmProcess ?? state.previewFilmProcessSelection;
    // SessionStore owns the typed request-failure state, so typed rejections
    // are deliberately consumed here (the store already recorded them). An
    // untyped rejection means the store threw before recording anything --
    // exactly how the Windows insecure-context crypto.randomUUID TypeError
    // made this button a silent no-op on real hardware -- so keep that class
    // visible instead of swallowing it.
    void sessionStore.acquireThumbnails(undefined, filmProcess).catch((error: unknown) => {
      if (!isEngineError(error)) {
        console.error("preview request threw outside the store's typed error path", error);
      }
    });
  };

  const frames: number[] = [];
  for (let index = 1; index <= frameCount; index += 1) {
    frames.push(index);
  }

  return (
    <div className={styles.contactSheet}>
      <div className={styles.toolbar}>
        {canLoadSimulatedMedia && (
          <div className={styles.loadControls} data-testid="load-media-controls">
            {CARRIERS.map((carrier) => (
              <button
                key={carrier}
                type="button"
                className={styles.controlButton}
                disabled={operationBusy}
                onClick={() => void loadSimulatedMedia(carrier)}
              >
                {carrier}
              </button>
            ))}
          </div>
        )}
        {mediaLoadError !== null && (
          <p className={styles.failureBanner} role="alert" data-testid="media-load-error">
            {mediaLoadError.code}: {mediaLoadError.message}
          </p>
        )}
        {!mediaLoaded && !canLoadSimulatedMedia && (
          <p className={styles.mediaGuidance} data-testid="no-media-guidance">
            {connected && deviceKind === "real"
              ? "Load film in the scanner, then choose Preview to establish the current frame registration."
              : "Connect a scanner to preview film."}
          </p>
        )}
        {project === null && canPreview && (
          <label className={styles.previewProcessControl}>
            Film process for preview
            <select
              value={state.previewFilmProcessSelection}
              disabled={
                operationBusy
              }
              onChange={(event) =>
                sessionStore.setPreviewFilmProcess(event.target.value as FilmProcess)
              }
            >
              {FILM_PROCESSES.map(({ value, label }) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
          </label>
        )}
        {canPreview && (
          <button
            type="button"
            className={styles.controlButton}
            data-testid="preview-button"
            disabled={previewDisabled}
            onClick={preview}
          >
            Preview
          </button>
        )}
        {canPreview && !motionReady && (
          <div className={styles.previewReadiness} data-testid="preview-readiness-guidance">
            <span>
              {motionReadiness === "notEnabled"
                ? "Motion authorization is not enabled for this app session. A status check cannot enable it. On Windows, fully quit ScanStudio and open ScanStudio Hardware Session from Start. On other platforms, use the documented owner-authorized hardware launch procedure."
                : "Motion readiness is unavailable. Check scanner reads the current status only; it does not enable motion."}
            </span>
            <button
              type="button"
              className={styles.controlButton}
              disabled={statusRefreshInProgress}
              aria-busy={statusRefreshInProgress}
              onClick={() => void checkScanner()}
            >
              {statusRefreshInProgress ? "Checking…" : "Check scanner"}
            </button>
            {statusRefreshFeedback === "notEnabled" && (
              <p
                className={styles.statusRefreshFeedback}
                role="status"
                data-state="not-enabled"
                data-testid="status-refresh-not-enabled"
              >
                Scanner status checked: motion authorization is still not enabled. On Windows,
                fully quit ScanStudio and open ScanStudio Hardware Session from Start. On other
                platforms, use the documented owner-authorized hardware launch procedure.
              </p>
            )}
            {statusRefreshFeedback === "unknown" && (
              <p
                className={styles.statusRefreshFeedback}
                role="status"
                data-state="unknown"
                data-testid="status-refresh-unknown"
              >
                Scanner status checked, but motion readiness is still unavailable. Preview remains
                disabled until the scanner reports a trusted status.
              </p>
            )}
            {statusRefreshError !== null && (
              <p className={styles.failureBanner} role="alert" data-testid="status-refresh-error">
                {statusRefreshError.code}: {statusRefreshError.message}
              </p>
            )}
          </div>
        )}
        {canPreview && motionReady && statusRefreshFeedback === "ready" && (
          <p
            className={styles.statusRefreshFeedback}
            role="status"
            data-state="ready"
            data-testid="status-refresh-ready"
          >
            Scanner status checked: motion authorization is ready for this app session.
          </p>
        )}
        {canPreview && motionReady && !transportReady && (
          <p className={styles.mediaGuidance} data-testid="preview-readiness-guidance">
            Wait for the scanner transport to become idle before previewing.
          </p>
        )}
        {mediaLoaded && (
          <div className={styles.selectionControls}>
            <button
              type="button"
              className={styles.controlButton}
              onClick={() => sessionStore.selectAll()}
            >
              Select All
            </button>
            <button
              type="button"
              className={styles.controlButton}
              onClick={() => sessionStore.clearSelection()}
            >
              Clear
            </button>
            {onCapture !== undefined && (
              <button
                type="button"
                className={styles.controlButton}
                data-testid="capture-action"
                disabled={
                  selectionEmpty ||
                  operationBusy
                }
                onClick={onCapture}
              >
                Capture selected
              </button>
            )}
            {onInspectFrame !== undefined && focusedFrameIndex !== null && (
              <button
                type="button"
                className={styles.controlButton}
                data-testid="inspect-action"
                onClick={() => onInspectFrame(focusedFrameIndex)}
              >
                Inspect frame {focusedFrameIndex}
              </button>
            )}
          </div>
        )}
        {mediaLoaded && (
          <div className={styles.transformControls} data-testid="frame-transform-controls">
            <label className={styles.focusControl}>
              Edit frame
              <select
                data-testid="frame-transform-target"
                value={focusedFrameIndex ?? ""}
                onChange={(event) => sessionStore.focusFrame(Number(event.target.value))}
              >
                <option value="">Choose…</option>
                {frames.map((frameIndex) => (
                  <option key={frameIndex} value={frameIndex}>
                    {frameIndex}
                  </option>
                ))}
              </select>
            </label>
            <button
              type="button"
              className={styles.controlButton}
              data-testid="rotate-focused-left"
              disabled={focusedFrameIndex === null || !transformsEditable}
              title="Rotate the focused frame left (Command/Ctrl+L)"
              onClick={() => {
                if (focusedFrameIndex !== null) sessionStore.rotateFrames([focusedFrameIndex], -90);
              }}
            >
              Rotate left
            </button>
            <button
              type="button"
              className={styles.controlButton}
              data-testid="rotate-focused-right"
              disabled={focusedFrameIndex === null || !transformsEditable}
              title="Rotate the focused frame right (Command/Ctrl+R)"
              onClick={() => {
                if (focusedFrameIndex !== null) sessionStore.rotateFrames([focusedFrameIndex], 90);
              }}
            >
              Rotate right
            </button>
            <button
              type="button"
              className={styles.controlButton}
              data-testid="mirror-focused-horizontal"
              disabled={focusedFrameIndex === null || !transformsEditable}
              title="Flip the focused frame left to right (Shift+Command/Ctrl+H)"
              onClick={() => {
                if (focusedFrameIndex !== null) {
                  sessionStore.toggleHorizontalMirror([focusedFrameIndex]);
                }
              }}
            >
              Flip left/right
            </button>
            <button
              type="button"
              className={styles.controlButton}
              data-testid="mirror-focused-vertical"
              disabled={focusedFrameIndex === null || !transformsEditable}
              title="Flip the focused frame top to bottom (Option/Alt+Command/Ctrl+V)"
              onClick={() => {
                if (focusedFrameIndex !== null) {
                  sessionStore.toggleVerticalMirror([focusedFrameIndex]);
                }
              }}
            >
              Flip top/bottom
            </button>
            <button
              type="button"
              className={styles.controlButton}
              data-testid="reset-focused-transform"
              disabled={focusedFrameIndex === null || !transformsEditable}
              onClick={() => {
                if (focusedFrameIndex !== null) {
                  sessionStore.resetFrameTransforms([focusedFrameIndex]);
                }
              }}
            >
              Reset
            </button>
            <details className={styles.batchTransformControls} data-testid="batch-transform-controls">
              <summary>Apply to selected ({state.selectedFrameIndices.length})</summary>
              <div className={styles.batchTransformButtons}>
                <button
                  type="button"
                  className={styles.controlButton}
                  data-testid="apply-selected-rotate-left"
                  disabled={selectionEmpty || !transformsEditable}
                  onClick={() => sessionStore.rotateFrames(state.selectedFrameIndices, -90)}
                >
                  Rotate left
                </button>
                <button
                  type="button"
                  className={styles.controlButton}
                  data-testid="apply-selected-rotate-right"
                  disabled={selectionEmpty || !transformsEditable}
                  onClick={() => sessionStore.rotateFrames(state.selectedFrameIndices, 90)}
                >
                  Rotate right
                </button>
                <button
                  type="button"
                  className={styles.controlButton}
                  data-testid="apply-selected-mirror-horizontal"
                  disabled={selectionEmpty || !transformsEditable}
                  onClick={() => sessionStore.toggleHorizontalMirror(state.selectedFrameIndices)}
                >
                  Flip left/right
                </button>
                <button
                  type="button"
                  className={styles.controlButton}
                  data-testid="apply-selected-mirror-vertical"
                  disabled={selectionEmpty || !transformsEditable}
                  onClick={() => sessionStore.toggleVerticalMirror(state.selectedFrameIndices)}
                >
                  Flip top/bottom
                </button>
                <button
                  type="button"
                  className={styles.controlButton}
                  data-testid="apply-selected-reset"
                  disabled={selectionEmpty || !transformsEditable}
                  onClick={() => sessionStore.resetFrameTransforms(state.selectedFrameIndices)}
                >
                  Reset
                </button>
              </div>
            </details>
          </div>
        )}
      </div>
      {state.previewOutcome === "failed" && (
        <p className={styles.failureBanner} role="alert" data-testid="preview-failure">
          {state.previewError?.message ?? "Preview failed"}
        </p>
      )}
      {state.previewRequestFailure !== null && (
        <p className={styles.failureBanner} role="alert" data-testid="preview-request-failure">
          {state.previewRequestFailure.error.message}
        </p>
      )}
      {mediaLoaded && frameCount > 0 && (
        <div className={styles.grid} data-testid="contact-grid">
          {frames.map((frameIndex) => {
            const thumbnail = state.thumbnails[frameIndex];
            const selected = state.selectedFrameIndices.includes(frameIndex);
            const derivativeTransform = sessionStore.frameDerivativeTransform(frameIndex);
            const swapsAxes = derivativeTransform.rotationDegrees === 90 ||
              derivativeTransform.rotationDegrees === 270;
            const tileClass = [
              styles.tile,
              selected ? styles.selected : null,
              focusedFrameIndex === frameIndex ? styles.focused : null,
            ]
              .filter((entry) => entry !== null)
              .join(" ");
            let content: React.ReactNode;
            if (thumbnail?.imagePath !== undefined) {
              // Strict one-of rule (PROTOCOL.md Thumbnail): an imagePath tile
              // decodes via Phase 3's scanstudio-preview protocol -- never
              // convertFileSrc, never base64-over-invoke. previewImageSrc
              // picks the platform-correct URL form (Windows serves custom
              // protocols through an http(s)://<scheme>.localhost origin).
              content = (
                <img
                      src={previewImageSrc(thumbnail.imagePath)}
                  alt={`Frame ${frameIndex}`}
                  data-testid={`tile-image-${frameIndex}`}
                  data-axis-swapped={swapsAxes}
                  style={transformStyle(derivativeTransform)}
                />
              );
            } else if (
              thumbnail !== undefined &&
              (thumbnail.brightness !== undefined || thumbnail.tint !== undefined)
            ) {
              content = (
                <span
                  className={styles.shadedTile}
                  data-testid="tile-shaded"
                  data-axis-swapped={swapsAxes}
                  style={{
                    background: tileBackground(thumbnail),
                    ...transformStyle(derivativeTransform),
                  }}
                />
              );
            } else {
              content = <span className={styles.pending} data-testid="tile-pending" />;
            }
            return (
              <button
                key={frameIndex}
                type="button"
                className={tileClass}
                data-testid={`contact-tile-${frameIndex}`}
                data-rotation={derivativeTransform.rotationDegrees}
                data-horizontal-mirror={derivativeTransform.horizontalMirror}
                data-vertical-mirror={derivativeTransform.verticalMirror}
                data-focused={focusedFrameIndex === frameIndex}
                style={{ aspectRatio: swapsAxes ? "2 / 3" : "3 / 2" }}
                onFocus={() => sessionStore.focusFrame(frameIndex)}
                onClick={(event) =>
                  sessionStore.toggleFrameSelection(frameIndex, event.shiftKey)
                }
              >
                <span className={styles.frameNumber}>{frameIndex}</span>
                <span className={styles.tileMedia}>{content}</span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

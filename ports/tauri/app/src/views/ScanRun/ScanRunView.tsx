import { useEffect, useMemo, useRef, useState } from "react";
import { useSyncExternalStore } from "react";
import { sessionStore, type SessionState } from "../../session";
import type { JobState, PendingFramesResult } from "../../session/wire/types";
import type { StopMode } from "../../session/store/session";
import type { EngineError, FrameState } from "../../session/wire/types";
import type { ScanReceipt } from "../../session/wire/types";
import styles from "./ScanRun.module.css";

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

const TERMINAL_JOB_STATES: JobState[] = ["completed", "stopped", "failed"];
const TICKER_LIMIT = 200;

export interface ScanRunViewProps {
  jobId: string;
  onResume?: (pending: PendingFramesResult) => void;
}

interface ProgressTick {
  id: number;
  label: string;
  severity: "info" | "error";
}

export function captureDurationLabel(durationMs: number): string {
  if (!Number.isFinite(durationMs) || durationMs <= 0) return "Capture timing not recorded";
  if (durationMs < 60_000) return `${(durationMs / 1_000).toFixed(1)}s capture`;
  const minutes = Math.floor(durationMs / 60_000);
  const seconds = Math.round((durationMs % 60_000) / 1_000);
  return `${minutes}m ${seconds}s capture`;
}

function receiptDetails(receipt: ScanReceipt): string[] {
  const details = [captureDurationLabel(receipt.durationMs)];
  if (receipt.nikonlook !== undefined) {
    details.push(`${receipt.nikonlook.bundleVersion} ${receipt.nikonlook.layerAPath}`);
  }
  if (receipt.autoCrop !== undefined) {
    details.push(receipt.autoCrop.applied ? "auto-cropped" : "auto-crop not applied");
  }
  const transform = receipt.outputs?.derivativeTransform;
  if (
    transform !== undefined &&
    (transform.rotationDegrees !== 0 || transform.horizontalMirror || transform.verticalMirror)
  ) {
    const parts = [`${transform.rotationDegrees}°`];
    if (transform.horizontalMirror) parts.push("left/right flip");
    if (transform.verticalMirror) parts.push("top/bottom flip");
    details.push(parts.join(" + "));
  }
  if (receipt.storageTransform !== undefined) {
    details.push(`storage ${receipt.storageTransform}`);
  }
  return details;
}

export default function ScanRunView({ jobId, onResume }: ScanRunViewProps) {
  const state = useSyncExternalStore(stableSubscribe, stableGetSnapshot);
  const jobState = state.jobState;
  const frameIndices = useMemo(
    () =>
      Object.keys(state.frameStates)
        .map(Number)
        .sort((a, b) => a - b),
    [state.frameStates],
  );
  const progress = state.scanProgress;
  const scannedFrameCount = Object.values(state.frameReceipts).filter(
    (receipts) => receipts.length > 0,
  ).length;
  // An "active" job is any job that has started but not reached a terminal
  // state; while one is running, ejecting media is disallowed (engine-enforced
  // too, but the UI mirrors it and stays disabled).
  const jobActive =
    jobState !== null && !TERMINAL_JOB_STATES.includes(jobState) && jobId === state.jobId;
  // Immediate stop is simulator-only capability (PROTOCOL.md: scan.stop
  // immediate is not real-hardware-safe; the connected backend exposes it
  // only when simulated).
  const supportsImmediateStop = state.connection.device?.kind === "simulated";
  const mediaLoaded = state.connection.connected && state.connection.status?.mediaLoaded === true;
  const [ejectPending, setEjectPending] = useState(false);
  const [ejectResult, setEjectResult] = useState<"succeeded" | EngineError | null>(null);

  // Cumulative event ticker built from store state changes: every frame-state
  // transition and every failing error produce an entry, capped at the 200
  // most recent (older entries drop). Errors keep their line even after the
  // store clears the error on a successful retry.
  const [ticker, setTicker] = useState<ProgressTick[]>([]);
  const tickerId = useRef(0);
  const prevStates = useRef<Record<number, FrameState>>(state.frameStates);
  const prevErrors = useRef<Record<number, EngineError>>(state.frameErrors);
  useEffect(() => {
    const entries: ProgressTick[] = [];
    const before = prevStates.current;
    const errorBefore = prevErrors.current;
    for (const frame of frameIndices) {
      const next = state.frameStates[frame];
      const prevState = before[frame];
      if (prevState !== next) {
        tickerId.current += 1;
        entries.push({
          id: tickerId.current,
          label: `frame ${frame}: ${prevState ?? "—"} → ${next}`,
          severity: "info",
        });
      }
    }
    for (const frame of Object.keys(state.frameErrors).map(Number)) {
      const error = state.frameErrors[frame];
      if (error !== undefined && errorBefore[frame] !== error) {
        tickerId.current += 1;
        entries.push({
          id: tickerId.current,
          label: `frame ${frame} failed: ${error.code} — ${error.message}`,
          severity: "error",
        });
      }
    }
    prevStates.current = state.frameStates;
    prevErrors.current = state.frameErrors;
    if (entries.length > 0) {
      setTicker((prev) => [...prev, ...entries].slice(-TICKER_LIMIT));
    }
  }, [frameIndices, state.frameStates, state.frameErrors]);

  const stop = async (mode: StopMode): Promise<void> => {
    await sessionStore.stopJob(jobId, mode);
  };

  const loadPending = async (): Promise<void> => {
    const pending = await sessionStore.pendingFrames();
    if (onResume !== undefined) onResume(pending);
  };

  const eject = async (): Promise<void> => {
    if (ejectPending) return;
    setEjectPending(true);
    setEjectResult(null);
    try {
      await sessionStore.eject();
      setEjectResult("succeeded");
    } catch (reason) {
      const error = reason as Partial<EngineError>;
      setEjectResult({
        code: typeof error.code === "string" ? error.code : "INTERNAL",
        message: typeof error.message === "string" ? error.message : "eject failed",
        recoverable: error.recoverable === true,
      });
    } finally {
      setEjectPending(false);
    }
  };

  return (
    <div className={styles.viewShell} data-testid="scan-run-view">
      <div className={styles.viewHeader}>
        <h2 className={styles.heading}>Scan Run</h2>
        <span className={styles.scannedCount} data-testid="frames-scanned-count">
          {scannedFrameCount} frame{scannedFrameCount === 1 ? "" : "s"} scanned
        </span>
        <span
          className={styles.jobStateBadge}
          data-testid="scan-run-jobstate"
          data-jobstate={jobState ?? "idle"}
        >
          {jobState ?? "idle"}
        </span>
      </div>

      {progress !== null && (
        <div className={styles.progressRow} data-testid="scan-run-progress">
          <span data-testid="scan-run-job-percent">{Math.round(progress.jobPercent)}%</span>
          <span data-testid="scan-run-eta">ETA {Math.round(progress.etaSeconds)}s</span>
        </div>
      )}

      {state.lastCompletedSummary?.dutyCycle !== undefined && (
        <p className={styles.hint} data-testid="scan-duty-cycle">
          Inter-frame idle: {Math.round(state.lastCompletedSummary.dutyCycle.meanIdleMs)} ms average,
          {" "}{state.lastCompletedSummary.dutyCycle.maxIdleMs} ms maximum
        </p>
      )}

      <div className={styles.controls}>
        <button
          type="button"
          className={styles.primaryButton}
          data-testid="stop-after-current"
          disabled={!jobActive}
          onClick={() => void stop("afterCurrentFrame")}
        >
          Stop after current frame
        </button>
        <p className={styles.hint} data-testid="stop-explanation">
          The current frame will finish before stopping.
        </p>
        {supportsImmediateStop && (
          <button
            type="button"
            className={styles.dangerButton}
            data-testid="stop-now"
            disabled={!jobActive}
            onClick={() => void stop("immediate")}
          >
            Stop now
          </button>
        )}
        <button
          type="button"
          className={styles.controlButton}
          data-testid="eject-control"
          disabled={jobActive || ejectPending || !mediaLoaded}
          onClick={() => void eject()}
        >
          {ejectPending ? "Ejecting…" : "Eject"}
        </button>
        {ejectResult === "succeeded" && (
          <p className={styles.hint} data-testid="eject-success">
            Eject completed.
          </p>
        )}
        {ejectResult !== null && ejectResult !== "succeeded" && (
          <p className={styles.frameError} data-testid="eject-error">
            {ejectResult.code} — {ejectResult.message}
          </p>
        )}
        <button
          type="button"
          className={styles.controlButton}
          data-testid="refresh-pending"
          onClick={() => void loadPending()}
        >
          Check remaining frames
        </button>
      </div>

      <div className={styles.frameTable} data-testid="scan-run-frames">
        {frameIndices.length === 0 && (
          <p className={styles.hint} data-testid="scan-run-no-frames">
            No frames in the current job yet.
          </p>
        )}
        {frameIndices.map((frame) => {
          const frameState: FrameState | undefined = state.frameStates[frame];
          const attempt = state.frameAttempts[frame];
          const error: EngineError | undefined = state.frameErrors[frame];
          const receipts = state.frameReceipts[frame] ?? [];
          const latestReceipt = receipts[receipts.length - 1];
          // Per PROTOCOL.md, frames never reached before a cooperative stop
          // are reported as `skipped` in scan.completed's summary, not via an
          // individual frameState event — union that authoritative list into
          // the display state so a stopped batch never looks like a failure.
          const skippedInSummary = state.lastCompletedSummary?.skipped.includes(frame) === true;
          const displayState =
            skippedInSummary && frameState !== "failed" && frameState !== "completed"
              ? "skipped"
              : frameState;
          return (
            <div
              className={styles.frameRow}
              key={frame}
              data-testid={`frame-row-${frame}`}
              data-state={displayState ?? "unknown"}
            >
              <span className={styles.frameIndex}>Frame {frame}</span>
              <span className={styles.frameStateBadge} data-testid={`frame-state-${frame}`}>
                {displayState ?? "unknown"}
                {attempt !== undefined && attempt > 1 ? ` (attempt ${attempt})` : ""}
              </span>
              {error !== undefined && frameState === "failed" && (
                <span
                  className={styles.frameError}
                  data-testid={`frame-error-${frame}`}
                  data-code={error.code}
                >
                  {error.code} — {error.message}
                </span>
              )}
              {latestReceipt !== undefined && (
                <span
                  className={styles.receiptSummary}
                  data-testid={`frame-receipt-${frame}`}
                  title={`Capture started ${latestReceipt.startedAt}`}
                >
                  {receiptDetails(latestReceipt).join(" · ")}
                </span>
              )}
            </div>
          );
        })}
      </div>

      <div className={styles.ticker} data-testid="scan-run-ticker">
        <h3 className={styles.tickerHeading}>Event log</h3>
        <ol className={styles.tickerList} data-testid="scan-run-ticker-list">
          {ticker.length === 0 && <li className={styles.tickerLine}>Waiting for job events…</li>}
          {ticker.map((tick) => (
            <li
              key={tick.id}
              className={tick.severity === "error" ? styles.tickerError : styles.tickerLine}
              data-testid="scan-run-tick"
            >
              {tick.label}
            </li>
          ))}
        </ol>
      </div>
    </div>
  );
}

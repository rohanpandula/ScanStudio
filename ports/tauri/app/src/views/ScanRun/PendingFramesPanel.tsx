import { useEffect, useState } from "react";
import type { ResolvedCaptureRecipe } from "../../session/store/session";
import type {
  CaptureRecipe,
  OutputRecipe,
  PendingFramesResult,
  ProcessingRecipe,
} from "../../session/wire/types";
import { sessionStore } from "../../session";
import styles from "./ScanRun.module.css";

export interface PendingFramesPanelProps {
  onResumed?: (jobId: string) => void;
  // The recipes the interrupted batch was started with, so a resume replays
  // the operator's configured destinations/templates/ICE instead of dropping
  // to hardcoded defaults.
  recipes?: {
    capture: ResolvedCaptureRecipe;
    processing?: ProcessingRecipe;
    output?: OutputRecipe;
  };
}

export default function PendingFramesPanel({ onResumed, recipes }: PendingFramesPanelProps) {
  const [pending, setPending] = useState<PendingFramesResult | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [refreshCount, setRefreshCount] = useState(0);
  const [checking, setChecking] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setChecking(true);
    setError(null);
    void sessionStore.pendingFrames()
      .then((result) => { if (!cancelled) setPending(result); })
      .catch((reason) => {
        if (!cancelled) setError(reason?.message ?? "Failed to load remaining frames. Try checking again.");
      })
      .finally(() => { if (!cancelled) setChecking(false); });
    return () => { cancelled = true; };
  }, [refreshCount]);

  const resume = async (): Promise<void> => {
    if (pending === null || pending.frames.length === 0 || checking || busy || error !== null) return;
    setError(null);
    setBusy(true);
    try {
      // Frames come from the store's pendingFrames result only, never a
      // client-recomputed list, so resume matches the engine's authoritative
      // pending set exactly.
      const recipe = recipes?.capture ?? {
        resolutionDpi: 4000,
        bitDepth: 16,
        multisamplePasses: 1,
        channels: "rgbi",
      } as CaptureRecipe;
      const result = await sessionStore.startScan(
        pending.frames,
        recipe,
        recipes?.processing,
        recipes?.output,
      );
      if (onResumed !== undefined) onResumed(result.jobId);
      setPending(null);
    } catch (reason) {
      setError((reason as { message?: string })?.message ?? "resume failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className={styles.pendingPanel} data-testid="pending-frames-panel">
      <div className={styles.pendingRow}>
        <div className={styles.pendingStats} data-testid="pending-frames-stats">
          {pending === null
            ? checking ? "Checking remaining frames…" : "Remaining frames unavailable."
            : `${pending.frames.length} of ${pending.totalFrames} pending · ${pending.completedCount} complete · ${pending.excludedCount} excluded`}
        </div>
        <button
          type="button"
          className={styles.controlButton}
          data-testid="load-pending-frames"
          disabled={checking || busy}
          onClick={() => {
            setChecking(true);
            setRefreshCount((count) => count + 1);
          }}
        >
          {checking ? "Checking…" : "Check remaining frames"}
        </button>
      </div>
      {pending !== null && pending.frames.length > 0 && (
        <button
          type="button"
          className={styles.resumeButton}
          data-testid="scan-remaining"
          disabled={busy || checking || error !== null}
          onClick={() => void resume()}
        >
          Scan remaining ({pending.frames.length})
        </button>
      )}
      {pending !== null && pending.frames.length === 0 && !checking && error === null && (
        <p className={styles.hint} role="status" data-testid="capture-workflow-done">
          {pending.completedCount === pending.totalFrames ? "All frames captured." : "No frames remaining."}
        </p>
      )}
      {error !== null && (
        <p className={styles.hint} role="alert" data-testid="pending-frames-error">
          {error}
        </p>
      )}
    </div>
  );
}

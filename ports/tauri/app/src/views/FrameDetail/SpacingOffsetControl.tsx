import { useEffect, useState, useSyncExternalStore } from "react";
import { sessionStore, type SessionState } from "../../session";
import { sessionOperationBusy } from "../../session/store/session";
import { previewImageSrc } from "../../session/webApis";
import styles from "./FrameDetail.module.css";

// useSyncExternalStore requires a referentially stable snapshot between
// store notifications, but SessionStore.getState() deep-clones on every call.
// Cache one snapshot per store generation here (same stable-snapshot bridge
// as DeviceBar/ContactSheet).
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

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, Math.round(value)));
}

function isFrameApproved(state: SessionState, frameIndex: number): boolean {
  const operationId = state.latestCompletedPreviewOperationId;
  if (operationId === null) return false;
  const approved = state.approvedFrames[operationId];
  return approved !== undefined && approved.includes(frameIndex);
}

function errorMessage(err: unknown): { code: string; message: string } {
  if (
    typeof err === "object" &&
    err !== null &&
    "code" in err &&
    "message" in err &&
    typeof (err as { code: unknown }).code === "string" &&
    typeof (err as { message: unknown }).message === "string"
  ) {
    return { code: (err as { code: string }).code, message: (err as { message: string }).message };
  }
  if (err instanceof Error) return { code: "ERROR", message: err.message };
  return { code: "ERROR", message: "Unknown error" };
}

export default function SpacingOffsetControl({ frameIndex }: { frameIndex: number }) {
  const state = useSyncExternalStore(stableSubscribe, stableGetSnapshot);
  const range = frameIndex === 1 ? { min: 0, max: 144 } : { min: -144, max: 144 };
  const thumbnail = state.thumbnails[frameIndex];
  const approved = isFrameApproved(state, frameIndex);
  const [value, setValue] = useState(String(thumbnail?.spacingOffset ?? 0));
  const [invalidated, setInvalidated] = useState(false);
  const [error, setError] = useState<{ code: string; message: string } | null>(null);

  // Keep the input in lockstep with the store-confirmed offset (e.g. the
  // replacement tile the bridge returned for a committed change).
  const confirmedOffset = thumbnail?.spacingOffset;
  useEffect(() => {
    if (confirmedOffset !== undefined) {
      setValue(String(confirmedOffset));
    }
  }, [confirmedOffset]);

  // Clearing the invalidation banner once the operator re-approves the frame.
  useEffect(() => {
    if (approved) setInvalidated(false);
  }, [approved]);

  const parsed = Number.parseInt(value, 10);
  const clampedDisplay = Number.isNaN(parsed) ? range.min : clamp(parsed, range.min, range.max);
  const adjustmentDisabled = sessionOperationBusy(state);

  const commit = async (raw: string): Promise<void> => {
    const parsedInput = Number.parseInt(raw, 10);
    if (Number.isNaN(parsedInput)) return;
    const clamped = clamp(parsedInput, range.min, range.max);
    setValue(String(clamped));
    setError(null);
    // Client-side clamp runs before any store call (T-06-03). The invalidation
    // banner tracks "this frame was approved, and the committed offset differs
    // from the thumbnail's prior spacingOffset" at commit time.
    const snapshot = sessionStore.getState();
    const priorThumbnail = snapshot.thumbnails[frameIndex];
    const priorOffset = priorThumbnail?.spacingOffset;
    const wasApproved = isFrameApproved(snapshot, frameIndex);
    if (wasApproved && priorOffset !== undefined && clamped !== priorOffset) {
      setInvalidated(true);
    }
    try {
      await sessionStore.setSpacingOffset(frameIndex, clamped);
    } catch (err) {
      // The store/engine remain authoritative and reject with INVALID_PARAMS;
      // render that diagnosis verbatim, never paraphrased.
      setError(errorMessage(err));
    }
  };

  const needsBadge = thumbnail?.needsApproval === true && !approved;

  return (
    <div className={styles.offsetControl} data-testid="spacing-offset-control">
      <div className={styles.tileRow}>
        {thumbnail?.imagePath !== undefined ? (
          <img
            className={styles.replacementTile}
            src={previewImageSrc(thumbnail.imagePath)}
            alt={`Frame ${frameIndex} replacement tile`}
            data-testid="replacement-tile"
          />
        ) : (
          <span className={styles.tilePlaceholder} data-testid="replacement-tile-placeholder">
            no tile
          </span>
        )}
        <span className={styles.rangeLabel} data-testid="spacing-offset-range">
          Range: {range.min}..{range.max}
        </span>
      </div>
      <div className={styles.inputRow}>
        <input
          id={`spacing-offset-${frameIndex}`}
          type="number"
          className={styles.numberInput}
          data-testid="spacing-offset-input"
          value={value}
          min={range.min}
          max={range.max}
          disabled={adjustmentDisabled}
          aria-label={`Spacing offset for frame ${frameIndex}`}
          onChange={(event) => setValue(event.target.value)}
          onBlur={() => void commit(value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") void commit(value);
          }}
        />
        <input
          type="range"
          className={styles.dragHandle}
          data-testid="spacing-offset-drag"
          min={range.min}
          max={range.max}
          disabled={adjustmentDisabled}
          step={1}
          value={clampedDisplay}
          aria-label={`Spacing offset drag handle for frame ${frameIndex}`}
          onChange={(event) => void commit(event.target.value)}
        />
      </div>
      {needsBadge && (
        <span className={styles.needsApprovalBadge} data-testid="spacing-needs-approval-badge">
          Needs approval
        </span>
      )}
      {invalidated && (
        <p className={styles.invalidatedBanner} role="status" data-testid="approval-invalidated-banner">
          Approval invalidated — re-approve before scanning
        </p>
      )}
      {error !== null && (
        <p className={styles.error} role="alert" data-testid="spacing-error">
          <span data-testid="spacing-error-code">{error.code}</span>:{" "}
          <span data-testid="spacing-error-message">{error.message}</span>
        </p>
      )}
    </div>
  );
}

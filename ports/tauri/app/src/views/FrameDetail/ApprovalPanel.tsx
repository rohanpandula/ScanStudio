import { useState, useSyncExternalStore } from "react";
import { sessionStore, type SessionState } from "../../session";
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

function isFrameApproved(state: SessionState, frameIndex: number): boolean {
  const operationId = state.latestCompletedPreviewOperationId;
  if (operationId === null) return false;
  const approved = state.approvedFrames[operationId];
  return approved !== undefined && approved.includes(frameIndex);
}

function errorMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  if (
    typeof err === "object" &&
    err !== null &&
    "message" in err &&
    typeof (err as { message: unknown }).message === "string"
  ) {
    return (err as { message: string }).message;
  }
  return "Unknown error";
}

export default function ApprovalPanel({ frameIndex }: { frameIndex: number }) {
  const state = useSyncExternalStore(stableSubscribe, stableGetSnapshot);
  const thumbnail = state.thumbnails[frameIndex];
  const approved = isFrameApproved(state, frameIndex);
  const [error, setError] = useState<string | null>(null);

  // The badge disappears as soon as the store reports the frame approved;
  // it cannot be edited away on the engine side, so re-render drives it.
  const needsBadge = thumbnail?.needsApproval === true && !approved;
  const warnings = thumbnail?.warnings ?? [];

  const approve = async (): Promise<void> => {
    setError(null);
    try {
      // Approving forwards the store's own completed-preview operationId; the
      // component never constructs or caches one (T-06-04).
      await sessionStore.approveFrame(frameIndex);
    } catch (err) {
      setError(errorMessage(err));
    }
  };

  return (
    <section className={styles.approvalPanel} data-testid="approval-panel">
      <div className={styles.approvalHeader}>
        <h3 className={styles.approvalTitle}>Approval</h3>
        {needsBadge && (
          <span className={styles.needsApprovalBadge} data-testid="approval-needs-badge">
            Needs approval
          </span>
        )}
        <button
          type="button"
          className={styles.controlButton}
          disabled={approved}
          onClick={() => void approve()}
        >
          Approve
        </button>
      </div>
      {error !== null && (
        <p className={styles.error} role="alert" data-testid="approval-error">
          {error}
        </p>
      )}
      {warnings.length > 0 && (
        <ul className={styles.warnings} data-testid="approval-warnings">
          {warnings.map((warning, index) => (
            // Plain text child, never dangerouslySetInnerHTML, never trimmed
            // or paraphrased (T-06-02).
            <li key={index} className={styles.warningItem}>
              {warning}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

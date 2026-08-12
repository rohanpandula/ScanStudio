import { useCallback, useEffect, useState } from "react";
import { useSyncExternalStore } from "react";
import { sessionStore, type SessionState } from "../../session";
import type { ResolvedCaptureRecipe } from "../../session/store/session";
import type {
  OutputRecipe,
  PendingFramesResult,
  ProcessingRecipe,
} from "../../session/wire/types";
import ScanSetupView from "../ScanSetup/ScanSetupView";
import ScanRunView from "../ScanRun/ScanRunView";
import PendingFramesPanel from "../ScanRun/PendingFramesPanel";
import styles from "./CaptureWorkflow.module.css";

let cachedStore: unknown = null;
let cachedSnapshot: Readonly<SessionState> | null = null;

function stableSubscribe(listener: () => void): () => void {
  // This view may be unmounted while Windows setup is visible. Discard a
  // snapshot retained from the prior mount so React's post-subscribe check
  // observes a job that became active while the view was away.
  cachedSnapshot = null;
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

const TERMINAL_JOB_STATES = ["completed", "stopped", "failed"];

export interface CaptureWorkflowViewProps {
  selectedFrames: number[];
  onRequestConnect: () => void;
  onOpenFrameDetail?: (frameIndex: number) => void;
}

export default function CaptureWorkflowView({
  selectedFrames,
  onRequestConnect,
  onOpenFrameDetail,
}: CaptureWorkflowViewProps) {
  const state = useSyncExternalStore(stableSubscribe, stableGetSnapshot);
  const [activeJobId, setActiveJobId] = useState<string | null>(null);
  const [pending, setPending] = useState<PendingFramesResult | null>(null);
  const [lastRecipes, setLastRecipes] = useState<
    | { capture: ResolvedCaptureRecipe; processing?: ProcessingRecipe; output?: OutputRecipe }
    | undefined
  >(undefined);

  const jobState = state.jobState;
  const jobTerminal =
    activeJobId !== null && jobState !== null && TERMINAL_JOB_STATES.includes(jobState);

  const onScanStarted = useCallback(
    (jobId: string, recipes?: { capture: ResolvedCaptureRecipe; processing?: ProcessingRecipe; output?: OutputRecipe }) => {
      if (recipes !== undefined) setLastRecipes(recipes);
      setActiveJobId(jobId);
    },
    [],
  );

  // After a terminal job, surface the pending-frames panel with the engine's
  // authoritative remaining set.
  useEffect(() => {
    if (!jobTerminal) return;
    void sessionStore
      .pendingFrames()
      .then((result) => setPending(result))
      .catch(() => setPending(null));
  }, [jobTerminal]);

  // A job already active in the store (e.g. restored session) drives the run
  // view directly.
  useEffect(() => {
    if (state.jobId !== null && state.jobState !== null && !jobTerminal) {
      setActiveJobId(state.jobId);
    }
  }, [state.jobId, state.jobState, jobTerminal]);

  // Once a job has started, keep the run panel mounted (even at a terminal
  // state — the terminal summary drives the skipped badging and the pending
  // panel appears beneath it).
  if (activeJobId !== null) {
    return (
      <div className={styles.shell} data-testid="capture-workflow-run">
        <ScanRunView jobId={activeJobId} />
        {jobTerminal && pending !== null && pending.frames.length > 0 && (
          <PendingFramesPanel
            recipes={lastRecipes}
            onResumed={(jobId) => {
              setActiveJobId(jobId);
              setPending(null);
            }}
          />
        )}
        {jobTerminal && pending !== null && pending.frames.length === 0 && (
          <p className={styles.doneNote} data-testid="capture-workflow-done">
            All frames captured.
          </p>
        )}
      </div>
    );
  }

  return (
    <div className={styles.shell} data-testid="capture-workflow-view">
      <ScanSetupView
        selectedFrames={selectedFrames}
        onScanStarted={onScanStarted}
        onRequestConnect={onRequestConnect}
      />
      <button
        type="button"
        className={styles.controlButton}
        data-testid="open-frame-detail"
        disabled={selectedFrames.length !== 1}
        onClick={() => {
          if (onOpenFrameDetail !== undefined && selectedFrames.length === 1) {
            onOpenFrameDetail(selectedFrames[0]);
          }
        }}
      >
        Inspect selected frame
      </button>
    </div>
  );
}

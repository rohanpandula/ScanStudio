import { useCallback, useEffect, useState } from "react";
import { useSyncExternalStore } from "react";
import { sessionStore, type SessionState } from "../../session";
import { sessionOperationBusy, type ResolvedCaptureRecipe } from "../../session/store/session";
import type {
  OutputRecipe,
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
  onBack?: () => void;
  onOpenFrameDetail?: (frameIndex: number) => void;
}

export default function CaptureWorkflowView({
  selectedFrames,
  onRequestConnect,
  onBack,
  onOpenFrameDetail,
}: CaptureWorkflowViewProps) {
  const state = useSyncExternalStore(stableSubscribe, stableGetSnapshot);
  const [activeJobId, setActiveJobId] = useState<string | null>(null);
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

  useEffect(() => {
    if (state.jobId === null) {
      setActiveJobId(null);
      setLastRecipes(undefined);
    } else if (state.jobState !== null && !TERMINAL_JOB_STATES.includes(state.jobState)) {
      setActiveJobId(state.jobId);
    }
  }, [state.jobId, state.jobState]);

  const back = onBack === undefined ? null : (
    <button
      type="button"
      className={styles.controlButton}
      disabled={sessionOperationBusy(state)}
      onClick={() => {
        if (!sessionOperationBusy(sessionStore.getState())) onBack();
      }}
    >
      Back to film
    </button>
  );

  // Once a job has started, keep the run panel mounted (even at a terminal
  // state — the terminal summary drives the skipped badging and the pending
  // panel appears beneath it).
  if (activeJobId !== null && activeJobId === state.jobId) {
    return (
      <div className={styles.shell} data-testid="capture-workflow-run">
        {back}
        <ScanRunView key={`run-${activeJobId}`} jobId={activeJobId} />
        {jobTerminal && (
          <PendingFramesPanel
            key={`pending-${activeJobId}`}
            recipes={lastRecipes}
            onResumed={setActiveJobId}
          />
        )}
      </div>
    );
  }

  return (
    <div className={styles.shell} data-testid="capture-workflow-view">
      {back}
      <ScanSetupView
        selectedFrames={selectedFrames}
        onScanStarted={onScanStarted}
        onRequestConnect={onRequestConnect}
      />
      <button
        type="button"
        className={styles.controlButton}
        data-testid="open-frame-detail"
        disabled={selectedFrames.length !== 1 || sessionOperationBusy(state)}
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

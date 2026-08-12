import { useEffect, useState } from "react";
import { useSyncExternalStore } from "react";
import AppShell from "./shell/AppShell";
import ContactSheet from "./views/ContactSheet";
import CaptureWorkflowView from "./views/Capture/CaptureWorkflowView";
import DeviceBar from "./views/DeviceBar";
import FrameDetailView from "./views/FrameDetail/FrameDetailView";
import ProjectPanel from "./views/ProjectPanel";
import SetupChecker from "./views/SetupChecker";
import { sessionStore, type SessionState } from "./session";
import styles from "./App.module.css";

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

type Workspace =
  | { kind: "contact" }
  | { kind: "frame-detail"; frameIndex: number }
  | { kind: "capture" }
  | { kind: "windows-setup" };

function isWindows(): boolean {
  return typeof navigator !== "undefined" && /\bWindows\b/i.test(navigator.userAgent);
}

function App() {
  const state = useSyncExternalStore(stableSubscribe, stableGetSnapshot);
  const [workspace, setWorkspace] = useState<Workspace>({ kind: "contact" });
  const [workspaceBeforeSetup, setWorkspaceBeforeSetup] = useState<Workspace | null>(null);
  const selectedFrames = state.selectedFrameIndices;
  const windows = isWindows();
  const hardwareJobActive =
    state.connection.device?.kind === "real" &&
    state.jobState !== null &&
    !["completed", "stopped", "failed"].includes(state.jobState);

  useEffect(() => {
    // A job may become active while setup is already visible (for example,
    // after a delayed scan.start response). Immediately restore the workspace
    // that owns Stop instead of leaving hardware controls behind setup.
    if (hardwareJobActive && workspace.kind === "windows-setup") {
      setWorkspace(workspaceBeforeSetup ?? { kind: "contact" });
      setWorkspaceBeforeSetup(null);
    }
  }, [hardwareJobActive, workspace.kind, workspaceBeforeSetup]);

  const toggleWindowsSetup = (): void => {
    if (workspace.kind === "windows-setup") {
      setWorkspace(workspaceBeforeSetup ?? { kind: "contact" });
      setWorkspaceBeforeSetup(null);
      return;
    }
    if (hardwareJobActive) return;
    setWorkspaceBeforeSetup(workspace);
    setWorkspace({ kind: "windows-setup" });
  };

  return (
    <AppShell
      sidebar={
        <>
          <DeviceBar />
          <ProjectPanel />
        </>
      }
      workspace={
        <div data-testid="app-workspace">
          {workspace.kind === "frame-detail" && (
            <FrameDetailView
              frameIndex={workspace.frameIndex}
              onClose={() => setWorkspace({ kind: "contact" })}
            />
          )}
          {workspace.kind === "capture" && (
            <CaptureWorkflowView
              selectedFrames={selectedFrames}
              onRequestConnect={() => setWorkspace({ kind: "contact" })}
              onOpenFrameDetail={(frameIndex) => setWorkspace({ kind: "frame-detail", frameIndex })}
            />
          )}
          {workspace.kind === "windows-setup" && <SetupChecker />}
          {workspace.kind === "contact" && (
            <ContactSheet
              onInspectFrame={(frameIndex) => setWorkspace({ kind: "frame-detail", frameIndex })}
              onCapture={() => setWorkspace({ kind: "capture" })}
            />
          )}
        </div>
      }
      inspector={
        windows ? (
          <div className={styles.windowsSetupPanel}>
            <h2 className={styles.windowsSetupHeading}>Windows setup</h2>
            <p className={styles.windowsSetupCopy}>
              Check WSL2, the scanner bridge, and USB access when you need to.
              Nothing is checked until you choose the action below.
            </p>
            <button
              type="button"
              className={styles.windowsSetupButton}
              data-testid="windows-setup-action"
              disabled={hardwareJobActive}
              title={hardwareJobActive ? "Stop controls stay visible while real hardware is scanning" : undefined}
              onClick={toggleWindowsSetup}
            >
              {workspace.kind === "windows-setup" ? "Back to film" : "Check Windows setup"}
            </button>
          </div>
        ) : null
      }
    />
  );
}

export default App;

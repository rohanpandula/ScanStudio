import { useState } from "react";
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
  const selectedFrames = state.selectedFrameIndices;
  const windows = isWindows();

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
              onClick={() =>
                setWorkspace((current) =>
                  current.kind === "windows-setup"
                    ? { kind: "contact" }
                    : { kind: "windows-setup" },
                )
              }
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

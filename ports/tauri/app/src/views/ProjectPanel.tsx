import { useEffect, useState, useSyncExternalStore } from "react";
import { homeDir } from "@tauri-apps/api/path";
import { open } from "@tauri-apps/plugin-dialog";
import { sessionStore, type SessionState } from "../session";
import {
  preProjectPreviewRegistration,
  sessionOperationBusy,
} from "../session/store/session";
import type { ProjectSummary } from "../session/wire/types";
import { frameCountRangeFor, validateFrameCount, type Carrier } from "./projectRules";
import styles from "./ProjectPanel.module.css";

// useSyncExternalStore requires a referentially stable snapshot between
// store notifications, but SessionStore.getState() deep-clones on every call.
// Cache one snapshot per store generation here (same pattern as DeviceBar).
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

const CARRIERS: Carrier[] = ["roll36", "strip6", "mounted"];
const FILM_PROCESSES = [
  "positive",
  "c41ColorNegative",
  "bwNegative",
  "kodachrome",
] as const;
type FilmProcess = (typeof FILM_PROCESSES)[number];

function messageOf(err: unknown): string {
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

export default function ProjectPanel() {
  const [name, setName] = useState("");
  const [carrier, setCarrier] = useState<Carrier>("roll36");
  const [frameCount, setFrameCount] = useState("36");
  const [filmProcess, setFilmProcess] = useState<FilmProcess>("positive");
  const [carrierConfirmed, setCarrierConfirmed] = useState(false);
  const [directory, setDirectory] = useState<string | undefined>(undefined);
  const [recent, setRecent] = useState<ProjectSummary[] | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const state = useSyncExternalStore(stableSubscribe, stableGetSnapshot);
  const project = state.project;
  const previewRegistration = preProjectPreviewRegistration(state);
  const operationBusy = sessionOperationBusy(state);

  useEffect(() => {
    if (previewRegistration === null) return;
    if (previewRegistration.carrier !== null) {
      setCarrier(previewRegistration.carrier);
      setCarrierConfirmed(true);
    } else {
      setCarrierConfirmed(false);
    }
    setFrameCount(String(previewRegistration.frameCount));
    setFilmProcess(previewRegistration.filmProcess);
  }, [
    previewRegistration?.operationId,
    previewRegistration?.carrier,
    previewRegistration?.frameCount,
    previewRegistration?.filmProcess,
  ]);

  useEffect(() => {
    let cancelled = false;
    sessionStore
      .listProjects()
      .then((result) => {
        if (!cancelled) {
          setRecent(
            [...result.projects].sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
          );
        }
      })
      .catch(() => {
        if (!cancelled) setRecent([]);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const resolvedCarrier = previewRegistration?.carrier ?? carrier;
  const count = previewRegistration?.frameCount ?? Number(frameCount);
  const resolvedFilmProcess = previewRegistration?.filmProcess ?? filmProcess;
  const range = frameCountRangeFor(resolvedCarrier);
  const validation = validateFrameCount(resolvedCarrier, count);
  const holderNeedsConfirmation =
    previewRegistration !== null &&
    previewRegistration.carrier === null &&
    !carrierConfirmed;
  const completedPreviewNeedsRecovery =
    project === null &&
    state.previewOutcome === "succeeded" &&
    state.previewFilmProcess !== null &&
    previewRegistration === null;
  const waitingForDetectedStatus =
    completedPreviewNeedsRecovery &&
    state.connection.device?.kind === "real" &&
    state.latestCompletedPreviewOperationId !== null &&
    state.previewStatusOperationId !== state.latestCompletedPreviewOperationId;
  const previewRegistrationIncomplete =
    completedPreviewNeedsRecovery && !waitingForDetectedStatus;
  const createDisabled =
    name.trim() === "" ||
    !validation.valid ||
    holderNeedsConfirmation ||
    completedPreviewNeedsRecovery ||
    submitting ||
    operationBusy;

  const pickDirectory = async (): Promise<void> => {
    try {
      const chosen = await open({
        directory: true,
        defaultPath: `${await homeDir()}ScanStudio Projects`,
        multiple: false,
      });
      if (chosen !== null) setDirectory(chosen);
    } catch {
      // Dialog unavailable (e.g. non-Tauri shell): keep the default directory.
    }
  };

  const submit = async (event: React.FormEvent<HTMLFormElement>): Promise<void> => {
    event.preventDefault();
    if (createDisabled) return;
    setError(null);
    setSubmitting(true);
    try {
      await sessionStore.createProject(
        name.trim(),
        resolvedCarrier,
        count,
        resolvedFilmProcess,
        directory,
      );
    } catch (err) {
      setError(messageOf(err));
    } finally {
      setSubmitting(false);
    }
  };

  const openRecent = async (summary: ProjectSummary): Promise<void> => {
    setError(null);
    try {
      await sessionStore.openProject(summary.directory);
    } catch (err) {
      setError(messageOf(err));
    }
  };

  const refreshPreviewStatus = async (): Promise<void> => {
    setError(null);
    try {
      await sessionStore.refreshStatus();
    } catch (err) {
      setError(messageOf(err));
    }
  };

  return (
    <div className={styles.panel}>
      {project !== null && (
        <div className={styles.banner} data-testid="active-project">
          <strong>{project.name}</strong>
          <span>{project.carrier}</span>
          <span>
            {project.frameCount} frames
          </span>
        </div>
      )}
      <h2 className={styles.heading}>New Project</h2>
      <form className={styles.form} onSubmit={(event) => void submit(event)}>
        <label htmlFor="project-name">Project name</label>
        <input
          id="project-name"
          type="text"
          value={name}
          onChange={(event) => setName(event.target.value)}
        />
        <label htmlFor="project-carrier">Carrier</label>
        <select
          id="project-carrier"
          value={resolvedCarrier}
          disabled={previewRegistration?.carrier !== null && previewRegistration !== null}
          onChange={(event) => {
            setCarrier(event.target.value as Carrier);
            setCarrierConfirmed(true);
          }}
        >
          {CARRIERS.map((option) => (
            <option key={option} value={option}>
              {option}
            </option>
          ))}
        </select>
        <label htmlFor="project-frame-count">Frame count</label>
        <input
          id="project-frame-count"
          type="number"
          min={range.min}
          max={range.max}
          value={previewRegistration === null ? frameCount : String(previewRegistration.frameCount)}
          readOnly={previewRegistration !== null}
          onChange={(event) => setFrameCount(event.target.value)}
        />
        <label htmlFor="project-film-process">Film process</label>
        <select
          id="project-film-process"
          value={resolvedFilmProcess}
          disabled={previewRegistration !== null}
          onChange={(event) => setFilmProcess(event.target.value as FilmProcess)}
        >
          {FILM_PROCESSES.map((option) => (
            <option key={option} value={option}>
              {option}
            </option>
          ))}
        </select>
        {previewRegistration !== null && (
          <p className={styles.registrationSummary} data-testid="preview-registration-summary">
            {previewRegistration.frameCount} frames detected with {previewRegistration.filmProcess}.
            {previewRegistration.carrier === null
              ? " Confirm the loaded film holder before creating the project."
              : " These values are locked to the completed preview."}
          </p>
        )}
        {waitingForDetectedStatus && (
          <>
            <p className={styles.registrationSummary} data-testid="preview-status-pending">
              Waiting for the scanner to report the detected holder and frame count.
            </p>
            <button
              type="button"
              className={styles.controlButton}
              data-testid="refresh-preview-status"
              disabled={operationBusy}
              onClick={() => void refreshPreviewStatus()}
            >
              Check scanner
            </button>
          </>
        )}
        {previewRegistrationIncomplete && (
          <p className={styles.registrationSummary} data-testid="preview-registration-incomplete">
            Preview registration is incomplete or a saved spacing adjustment could not be
            restored. Choose Preview again before creating the project.
          </p>
        )}
        {previewRegistration !== null &&
          previewRegistration.carrier === null &&
          !carrierConfirmed && (
            <button
              type="button"
              className={styles.controlButton}
              data-testid="confirm-preview-carrier"
              onClick={() => setCarrierConfirmed(true)}
            >
              Confirm {carrier} holder
            </button>
          )}
        <div className={styles.directoryRow}>
          <button type="button" className={styles.controlButton} onClick={() => void pickDirectory()}>
            Choose output folder
          </button>
          {directory !== undefined && <span className={styles.directory}>{directory}</span>}
        </div>
        {!validation.valid && (
          <p className={styles.inlineError} role="alert" data-testid="frame-count-error">
            {validation.message}
          </p>
        )}
        <button type="submit" className={styles.controlButton} disabled={createDisabled}>
          Create
        </button>
      </form>
      {error !== null && (
        <p className={styles.error} role="alert" data-testid="project-error">
          {error}
        </p>
      )}
      <h3 className={styles.heading}>Open Recent</h3>
      <ul className={styles.recentList}>
        {(recent ?? []).map((summary) => (
          <li key={summary.id}>
            <button
              type="button"
              className={styles.recentRow}
              data-testid={`recent-project-${summary.id}`}
              disabled={
                operationBusy || submitting
              }
              onClick={() => void openRecent(summary)}
            >
              <span className={styles.recentName}>{summary.name}</span>
              <span className={styles.recentMeta}>
                {summary.carrier} · {summary.frameCount} frames
              </span>
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}

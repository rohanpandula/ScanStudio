import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { sessionStore, type SessionState } from "../session";
import { sessionOperationBusy } from "../session/store/session";
import type { DeviceInfo, EngineError } from "../session/wire/types";
import DiagnosticReportActions from "./DiagnosticReportActions";
import HardwareErrorPanel from "./HardwareErrorPanel";
import HardwareStatusChips from "./HardwareStatusChips";
import styles from "./DeviceBar.module.css";

// useSyncExternalStore requires a referentially stable snapshot between
// store notifications, but SessionStore.getState() deep-clones on every call.
// Cache one snapshot per store generation here: the cache is invalidated on
// each notification (and on store identity change, e.g. fixture swaps in
// tests), so React sees the same object until the store actually changes.
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

function connectionErrorOf(error: unknown): EngineError {
  if (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    "message" in error &&
    typeof (error as { code: unknown }).code === "string" &&
    typeof (error as { message: unknown }).message === "string"
  ) {
    return {
      code: (error as { code: string }).code,
      message: (error as { message: string }).message,
      recoverable:
        "recoverable" in error &&
        typeof (error as { recoverable: unknown }).recoverable === "boolean"
          ? (error as { recoverable: boolean }).recoverable
          : false,
    };
  }
  return {
    code: "INTERNAL",
    message: error instanceof Error ? error.message : "scanner connection request failed",
    recoverable: false,
  };
}

export default function DeviceBar() {
  const [devices, setDevices] = useState<DeviceInfo[] | null>(null);
  const [connectionPending, setConnectionPending] = useState<string | null>(null);
  const connectionPendingRef = useRef(false);
  const [connectionError, setConnectionError] = useState<EngineError | null>(null);
  const [rescanPending, setRescanPending] = useState(false);

  useEffect(() => {
    let cancelled = false;
    sessionStore
      .listDevices()
      .then((result) => {
        if (!cancelled) setDevices(result.devices);
      })
      .catch(() => {
        if (!cancelled) setDevices([]);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const state = useSyncExternalStore(stableSubscribe, stableGetSnapshot);
  const connected = state.connection.connected;
  const status = state.connection.status;
  const device = state.connection.device;
  const operationBusy = sessionOperationBusy(state);
  const visibleError =
    state.previewRequestFailure?.error ??
    state.filmFeedInterrupted ??
    connectionError;

  const connect = async (deviceId: string): Promise<void> => {
    if (connectionPendingRef.current || operationBusy) return;
    connectionPendingRef.current = true;
    setConnectionPending(deviceId);
    setConnectionError(null);
    try {
      await sessionStore.connect(deviceId);
    } catch (error) {
      setConnectionError(connectionErrorOf(error));
    } finally {
      connectionPendingRef.current = false;
      setConnectionPending(null);
    }
  };

  const disconnect = async (): Promise<void> => {
    if (connectionPendingRef.current || operationBusy) return;
    connectionPendingRef.current = true;
    setConnectionPending("disconnect");
    setConnectionError(null);
    try {
      await sessionStore.disconnect();
    } catch (error) {
      setConnectionError(connectionErrorOf(error));
    } finally {
      connectionPendingRef.current = false;
      setConnectionPending(null);
    }
  };
  // Hardware tri-state chips only ever mount for a real backend session --
  // the simulator omits motionArmed/filmPresent entirely (PROTOCOL.md:
  // "null is never absence"; the simulator omits the field rather than
  // fabricating a hardware-ready state). DeviceInfo.kind is the current
  // simulated/real backend discriminator.
  const isRealBackend = device?.kind === "real";

  // WV-2 (first live Windows validation): device discovery ran only at app
  // launch, so a WSL bridge stack that became healthy afterwards left the
  // real scanner invisible until a full app restart. Rescan asks the engine
  // for one deliberate re-attempt; the engine refuses it while connected,
  // so the button is disabled then rather than surfacing that refusal.
  const rescan = async (): Promise<void> => {
    if (rescanPending || connected || operationBusy) return;
    setRescanPending(true);
    try {
      const result = await sessionStore.rescanDevices();
      setDevices(result.devices);
      // Deliberately does NOT clear connectionError: a rescan succeeding
      // says nothing about an earlier connect failure the operator has not
      // yet read (review round 2).
    } catch (error) {
      setConnectionError(connectionErrorOf(error));
    } finally {
      setRescanPending(false);
    }
  };

  return (
    <div className={styles.deviceBar}>
      <h2 className={styles.heading}>Devices</h2>
      <button
        type="button"
        className={styles.controlButton}
        onClick={() => void rescan()}
        disabled={rescanPending || connected || operationBusy}
        data-testid="rescan-devices"
      >
        {rescanPending ? "Rescanning…" : "Rescan"}
      </button>
      <ul className={styles.deviceList}>
        {(devices ?? []).map((listedDevice) => {
          const isActive =
            connected && device?.deviceId === listedDevice.deviceId;
          const connectionBlocked = connected && !isActive;

          return (
            <li
              key={listedDevice.deviceId}
              className={styles.deviceCard}
              data-testid={`device-card-${listedDevice.deviceId}`}
            >
              <div className={styles.deviceModel}>{listedDevice.model}</div>
              <span className={styles.kindBadge}>{listedDevice.kind}</span>
              {isActive ? (
                <>
                  <span className={styles.connectionState}>Active</span>
                  <button
                    type="button"
                    className={styles.controlButton}
                    disabled={operationBusy || connectionPending !== null}
                    onClick={() => void disconnect()}
                  >
                    Disconnect
                  </button>
                </>
              ) : (
                <>
                  {connectionBlocked && (
                    <span className={styles.connectionHint}>
                      Disconnect active device first
                    </span>
                  )}
                  <button
                    type="button"
                    className={styles.controlButton}
                    disabled={
                      connectionBlocked || operationBusy || connectionPending !== null
                    }
                    onClick={() => void connect(listedDevice.deviceId)}
                  >
                    Connect
                  </button>
                </>
              )}
            </li>
          );
        })}
      </ul>
      {status !== null && (
        <dl className={styles.statusBlock} data-testid="scanner-status">
          <div className={styles.statusRow}>
            <dt>Lamp</dt>
            <dd>{status.lamp}</dd>
          </div>
          <div className={styles.statusRow}>
            <dt>Transport</dt>
            <dd>{status.transport}</dd>
          </div>
          <div className={styles.statusRow}>
            <dt>{isRealBackend ? "Preview registration" : "Media"}</dt>
            <dd>
              {isRealBackend
                ? status.mediaLoaded
                  ? "Established"
                  : "Not established"
                : status.mediaLoaded
                  ? "Media loaded"
                  : "No media"}
            </dd>
          </div>
          {status.frameCount !== null && (
            <div className={styles.statusRow}>
              <dt>Frames</dt>
              <dd>
                {status.frameCount} frames
              </dd>
            </div>
          )}
        </dl>
      )}
      {isRealBackend && status !== null && (
        <HardwareStatusChips
          motionArmed={status.motionArmed ?? null}
          filmPresent={status.filmPresent ?? null}
        />
      )}
      <HardwareErrorPanel
        error={visibleError}
        thumbnailsFailed={
          state.previewOutcome === "failed" ? state.previewError : null
        }
      />
      <DiagnosticReportActions
        error={visibleError}
        thumbnailsFailed={
          state.previewOutcome === "failed" ? state.previewError : null
        }
        device={device}
        status={status}
        thumbnails={state.thumbnails}
      />
    </div>
  );
}

import { useEffect, useState, useSyncExternalStore } from "react";
import { sessionStore, type SessionState } from "../session";
import type { DeviceInfo } from "../session/wire/types";
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

export default function DeviceBar() {
  const [devices, setDevices] = useState<DeviceInfo[] | null>(null);

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
  // Hardware tri-state chips only ever mount for a real backend session --
  // the simulator omits motionArmed/filmPresent entirely (PROTOCOL.md:
  // "null is never absence"; the simulator omits the field rather than
  // fabricating a hardware-ready state). DeviceInfo.kind is the current
  // simulated/real backend discriminator.
  const isRealBackend = device?.kind === "real";

  return (
    <div className={styles.deviceBar}>
      <h2 className={styles.heading}>Devices</h2>
      <ul className={styles.deviceList}>
        {(devices ?? []).map((device) => (
          <li
            key={device.deviceId}
            className={styles.deviceCard}
            data-testid={`device-card-${device.deviceId}`}
          >
            <div className={styles.deviceModel}>{device.model}</div>
            <span className={styles.kindBadge}>{device.kind}</span>
            {connected ? (
              <button
                type="button"
                className={styles.controlButton}
                onClick={() => void sessionStore.disconnect()}
              >
                Disconnect
              </button>
            ) : (
              <button
                type="button"
                className={styles.controlButton}
                onClick={() => void sessionStore.connect(device.deviceId)}
              >
                Connect
              </button>
            )}
          </li>
        ))}
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
        error={state.filmFeedInterrupted}
        thumbnailsFailed={
          state.previewOutcome === "failed" ? state.previewError : null
        }
      />
      <DiagnosticReportActions
        error={state.filmFeedInterrupted}
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

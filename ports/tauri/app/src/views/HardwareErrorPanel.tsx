import type { EngineError } from "../session/wire/types";
import styles from "./HardwareStatus.module.css";

export interface HardwareErrorPanelProps {
  error: EngineError | null;
  thumbnailsFailed?: { code: string; message: string } | null;
}

/**
 * Typed hardware error panel (UI-13). Two distinct input channels:
 *  - `error`  : a typed request rejection (EngineError) -- FEEDER_PARKED and
 *    HW_MOTION_NOT_ARMED are special-cased; any other code falls back to a
 *    generic verbatim-message rendering.
 *  - `thumbnailsFailed`: a scanner.thumbnailsFailed-shaped event payload --
 *    rendered as a clearly-FAILED preview state (never an empty success),
 *    per PROTOCOL.md's rule that zero-count completion preceded by this event
 *    is a failure.
 *
 * Safety (SAFE-02 / BRIDGE.md): for FEEDER_PARKED this component renders the
 * bridge message verbatim plus power-cycle guidance and MUST NOT offer any
 * retry or eject control -- retry decisions belong to the operator at the
 * machine, and a client must NEVER auto-retry an eject outcome. For
 * HW_MOTION_NOT_ARMED it explains the latch is operator-owned and MUST NOT
 * offer an in-app arm action (the app never arms motion).
 */
export default function HardwareErrorPanel({
  error,
  thumbnailsFailed,
}: HardwareErrorPanelProps) {
  if (thumbnailsFailed !== null && thumbnailsFailed !== undefined) {
    return (
      <div className={styles.errorPanel} data-testid="hardware-error-panel">
        <p className={styles.errorTitle} data-testid="preview-failed-state">
          Preview failed
        </p>
        <p className={styles.errorCode} data-testid="preview-failed-code">
          {thumbnailsFailed.code}
        </p>
        <p className={styles.errorMessage} data-testid="preview-failed-message">
          {thumbnailsFailed.message}
        </p>
      </div>
    );
  }

  if (error === null) return null;

  if (error.code === "FILM_FEED_INTERRUPTED") {
    return (
      <div
        className={styles.errorPanel}
        data-testid="hardware-error-panel"
        data-code="FILM_FEED_INTERRUPTED"
      >
        <p className={styles.errorTitle}>Film feed interrupted</p>
        <p className={styles.errorMessage} data-testid="film-feed-interrupted-message">
          {error.message}
        </p>
        <p className={styles.guidance} data-testid="film-feed-interrupted-guidance">
          Your finished frames are safe. Reinsert the film, acquire a fresh preview,
          then resume only the remaining frames.
        </p>
      </div>
    );
  }

  if (error.code === "FEEDER_PARKED") {
    return (
      <div className={styles.errorPanel} data-testid="hardware-error-panel" data-code="FEEDER_PARKED">
        <p className={styles.errorTitle}>Feeder parked</p>
        <p className={styles.errorMessage} data-testid="feeder-parked-message">
          {error.message}
        </p>
        <p className={styles.guidance} data-testid="feeder-parked-guidance">
          A power cycle is the only demonstrated recovery. Do not auto-retry an
          eject — retry decisions belong to the operator at the machine.
        </p>
      </div>
    );
  }

  if (error.code === "HW_MOTION_NOT_ARMED") {
    return (
      <div
        className={styles.errorPanel}
        data-testid="hardware-error-panel"
        data-code="HW_MOTION_NOT_ARMED"
      >
        <p className={styles.errorTitle}>Motion not armed</p>
        <p className={styles.errorMessage} data-testid="motion-not-armed-message">
          {error.message}
        </p>
        <p className={styles.guidance} data-testid="motion-independent-guidance">
          Motion authorization is operator-owned. Reopen ScanStudio using the
          documented owner-authorized hardware launch procedure. The app never
          enables motion on your behalf.
        </p>
      </div>
    );
  }

  return (
    <div className={styles.errorPanel} data-testid="hardware-error-panel">
      <p className={styles.errorCode} data-testid="generic-error-code">
        {error.code}
      </p>
      <p className={styles.errorMessage} data-testid="generic-error-message">
        {error.message}
      </p>
    </div>
  );
}

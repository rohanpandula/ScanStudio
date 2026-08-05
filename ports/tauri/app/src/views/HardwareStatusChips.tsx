import styles from "./HardwareStatus.module.css";

export interface HardwareStatusChipsProps {
  motionArmed: boolean | null;
  filmPresent: boolean | null;
}

/**
 * Real-backend hardware tri-state chips (UI-13). This component MUST only be
 * mounted by its caller when a real backend session exists -- the simulator
 * omits motionArmed/filmPresent entirely (PROTOCOL.md), so omitting this
 * whole component for a simulated device is the caller's responsibility, not
 * this component's. Each chip is independently three-state:
 *   true  = a real, live, no-motion read (Armed / Present)
 *   false = a real, live, no-motion read (Not Armed / Not Present)
 *   null  = real backend, no trustworthy verdict available yet (Unknown)
 * "Unknown" is rendered explicitly for null -- never blank, never visually
 * identical to the true/false states (PROTOCOL.md: "null is never absence").
 */
export default function HardwareStatusChips({
  motionArmed,
  filmPresent,
}: HardwareStatusChipsProps) {
  return (
    <div className={styles.chips} data-testid="hardware-status-chips">
      <span
        className={styles.chip}
        data-state={motionArmed === null ? "unknown" : motionArmed ? "armed" : "not-armed"}
        data-testid="motion-chip"
      >
        Motion: {motionArmed === null ? "Unknown" : motionArmed ? "Armed" : "Not Armed"}
      </span>
      <span
        className={styles.chip}
        data-state={filmPresent === null ? "unknown" : filmPresent ? "present" : "not-present"}
        data-testid="film-chip"
      >
        Film: {filmPresent === null ? "Unknown" : filmPresent ? "Present" : "Not Present"}
      </span>
    </div>
  );
}

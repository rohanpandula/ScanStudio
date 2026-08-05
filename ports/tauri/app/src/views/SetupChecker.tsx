import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import styles from "./SetupChecker.module.css";

export type ProbeStatus = "Ok" | "Fail" | "Unknown";

// Wire shapes mirror checker::ProbeResult / checker::MaxReadReport with serde's
// default camelCase field renaming.
export interface ProbeResult {
  id: string;
  status: ProbeStatus;
  detail: string;
  fixCommand: string | null;
}

export interface MaxReadReport {
  maxBytes: number | null;
  entriesScanned: number;
}

function badge(status: ProbeStatus): string {
  return status.toUpperCase();
}

/**
 * Windows WSL2 setup diagnostics screen (08-02, WSL-03). Runs the read-only
 * probe set on mount and renders each probe's id / status badge / detail /
 * copy-paste fix command, plus the active WSL write mode and the bridge
 * telemetry max-single-read readout. The fix commands are display-only text —
 * this component (and the Rust probes behind it) never install, elevate, or
 * execute anything. All process-shaped output renders via plain JSX text
 * interpolation (never dangerouslySetInnerHTML), so React escapes it.
 */
export default function SetupChecker() {
  const [probes, setProbes] = useState<ProbeResult[] | null>(null);
  const [maxRead, setMaxRead] = useState<MaxReadReport | null>(null);
  const [writeMode, setWriteMode] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    Promise.all([
      invoke<ProbeResult[]>("wsl_run_checks"),
      invoke<MaxReadReport>("wsl_max_read_report"),
      invoke<string>("wsl_write_mode_report"),
    ])
      .then(([probeResults, maxReadReport, mode]) => {
        if (cancelled) return;
        setProbes(probeResults);
        setMaxRead(maxReadReport);
        setWriteMode(mode);
      })
      .catch(() => {
        if (cancelled) return;
        setProbes([]);
        setMaxRead({ maxBytes: null, entriesScanned: 0 });
        setWriteMode("");
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (probes === null || maxRead === null || writeMode === null) {
    return (
      <div className={styles.viewShell} data-testid="setup-checker-loading">
        <p>Checking...</p>
      </div>
    );
  }

  return (
    <div className={styles.viewShell} data-testid="setup-checker">
      <h2 className={styles.heading}>Windows Setup Checker</h2>
      {writeMode !== "" && (
        <p className={styles.writeMode} data-testid="write-mode-row">
          <strong>Write mode:</strong> {writeMode}
        </p>
      )}
      <table className={styles.probeTable}>
        <thead>
          <tr>
            <th>Probe</th>
            <th>Status</th>
            <th>Detail</th>
            <th>Fix</th>
          </tr>
        </thead>
        <tbody>
          {probes.map((probe) => (
            <tr key={probe.id} data-testid={`probe-${probe.id}`}>
              <td>{probe.id}</td>
              <td>
                <span className={styles.badge} data-status={probe.status}>
                  {badge(probe.status)}
                </span>
              </td>
              <td>{probe.detail}</td>
              <td>{probe.fixCommand !== null ? <code>{probe.fixCommand}</code> : null}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className={styles.maxReadLine} data-testid="max-read-line">
        {maxRead.maxBytes !== null
          ? `max single read observed: ${maxRead.maxBytes} bytes across ${maxRead.entriesScanned} scan.call entries`
          : `no size data recorded in ${maxRead.entriesScanned} scan.call entries (bridge telemetry does not yet emit a byte-size field on scan.call exit entries)`}
      </p>
    </div>
  );
}

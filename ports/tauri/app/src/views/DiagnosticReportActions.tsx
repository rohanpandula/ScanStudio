import { useEffect, useState } from "react";
import { save } from "@tauri-apps/plugin-dialog";
import { diagnosticTimeline } from "../session";
import { buildDiagnosticBundleZip, resolveDiagnosticBundleRaster } from "../session/diagnosticBundle";
import { readPreviewRasterBytes, writeDiagnosticBundleFile } from "../session/diagnosticBundleIO";
import { buildErrorReportText, type ErrorReportContext, type SetupCheckProbeSummary } from "../session/errorReport";
import { describeCpuArchitecture, describeOperatingSystem, getScanStudioVersion } from "../session/hostEnvironment";
import { setupCheckResults } from "../session/setupCheckResults";
import type { DeviceInfo, EngineError, ScannerStatus, Thumbnail } from "../session/wire/types";

export interface DiagnosticReportActionsProps {
  error: EngineError | null;
  thumbnailsFailed: { code: string; message: string } | null;
  device: DeviceInfo | null;
  status: ScannerStatus | null;
  thumbnails: Record<number, Thumbnail>;
}

function timestampForFilename(): string {
  return new Date().toISOString().replace(/:/g, "");
}

/** "Copy Report" and "Save Diagnostic Bundle..." (error report v2, T-ERR-01
 * through T-ERR-04). Mounted next to HardwareErrorPanel, but deliberately a
 * sibling component rather than an edit to it: HardwareErrorPanel's
 * FEEDER_PARKED / HW_MOTION_NOT_ARMED branches carry careful
 * never-offer-a-retry safety guidance (SAFE-02) that this feature has no
 * reason to touch. Renders nothing while there is no active error, mirroring
 * the mac build's WorkspaceErrorBanner (only shown for an active
 * lastErrorMessage). */
export default function DiagnosticReportActions({
  error,
  thumbnailsFailed,
  device,
  status,
  thumbnails,
}: DiagnosticReportActionsProps) {
  const [didCopyReport, setDidCopyReport] = useState(false);
  const [isSavingBundle, setIsSavingBundle] = useState(false);
  const [didSaveBundle, setDidSaveBundle] = useState(false);

  // thumbnailsFailed takes precedence over a typed request rejection,
  // mirroring HardwareErrorPanel's own branch order.
  const errorCode = thumbnailsFailed?.code ?? error?.code ?? null;
  const errorMessage = thumbnailsFailed?.message ?? error?.message ?? null;

  useEffect(() => {
    if (errorCode === null) return;
    diagnosticTimeline.record("error.surfaced", { code: errorCode });
  }, [errorCode]);

  if (errorCode === null || errorMessage === null) {
    return null;
  }

  const buildReportContext = async (): Promise<ErrorReportContext> => {
    const scanStudioVersion = await getScanStudioVersion();
    const probes = setupCheckResults.get();
    const setupCheckProbes: SetupCheckProbeSummary[] | null = probes
      ? probes.map(({ id, status: probeStatus, detail }) => ({ id, status: probeStatus, detail }))
      : null;
    return {
      scanStudioVersion,
      operatingSystem: describeOperatingSystem(),
      cpuArchitecture: describeCpuArchitecture(),
      scannerFirmware: device?.firmware ?? null,
      scannerAdapter: status?.adapter ?? null,
      scannerHolder: status?.carrier ?? null,
      // No durable on-disk diagnostics log on the Tauri side yet (see
      // diagnosticTimeline.ts) -- rendering "unknown" here is honest, not a
      // placeholder bug: "Save Diagnostic Bundle..." below still captures
      // this session's full in-memory diagnostics.jsonl regardless.
      diagnosticLogPath: null,
      diagnosticSessionId: diagnosticTimeline.sessionId,
      recentDiagnosticEvents: diagnosticTimeline.summaryLines,
      errorCode,
      errorMessage,
      setupCheckProbes,
    };
  };

  const handleCopyReport = async (): Promise<void> => {
    const text = buildErrorReportText(await buildReportContext());
    await navigator.clipboard.writeText(text);
    setDidCopyReport(true);
    setTimeout(() => setDidCopyReport(false), 1500);
  };

  const handleSaveDiagnosticBundle = async (): Promise<void> => {
    setIsSavingBundle(true);
    try {
      const reportText = buildErrorReportText(await buildReportContext());
      const { raster, unavailableReason } = await resolveDiagnosticBundleRaster(
        thumbnails,
        readPreviewRasterBytes,
      );
      const zipBytes = buildDiagnosticBundleZip({
        diagnosticsJsonl: diagnosticTimeline.toJsonl(),
        reportText,
        previewRaster: raster,
        unavailableRasterReason: unavailableReason,
      });

      const destination = await save({
        title: "Save Diagnostic Bundle",
        defaultPath: `ScanStudio-Diagnostics-${timestampForFilename()}.zip`,
        filters: [{ name: "Zip Archive", extensions: ["zip"] }],
      });
      if (destination === null) return;

      await writeDiagnosticBundleFile(destination, zipBytes);
      setDidSaveBundle(true);
      setTimeout(() => setDidSaveBundle(false), 1500);
    } finally {
      setIsSavingBundle(false);
    }
  };

  return (
    <div data-testid="diagnostic-report-actions">
      <button type="button" onClick={() => void handleCopyReport()} data-testid="copy-report">
        {didCopyReport ? "Copied" : "Copy Report"}
      </button>
      <button
        type="button"
        onClick={() => void handleSaveDiagnosticBundle()}
        disabled={isSavingBundle}
        data-testid="save-diagnostic-bundle"
      >
        {didSaveBundle ? "Saved" : "Save Diagnostic Bundle…"}
      </button>
    </div>
  );
}

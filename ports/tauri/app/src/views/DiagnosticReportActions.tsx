import { useEffect, useState } from "react";
import { diagnosticTimeline } from "../session";
import {
  buildDiagnosticBundleZip,
  resolveDiagnosticBundleRasterCandidate,
  selectDiagnosticBundleRasterCandidate,
  type PreviewRasterCandidate,
} from "../session/diagnosticBundle";
import { readPreviewRasterBytes, saveDiagnosticBundleFile } from "../session/diagnosticBundleIO";
import { buildErrorReportText, type ErrorReportContext, type SetupCheckProbeSummary } from "../session/errorReport";
import { describeCpuArchitecture, describeOperatingSystem, getScanStudioVersion } from "../session/hostEnvironment";
import { setupCheckResults } from "../session/setupCheckResults";
import { useClipboardCopy } from "./useClipboardCopy";
import type { DeviceInfo, EngineError, ScannerStatus, Thumbnail } from "../session/wire/types";
import type { DiagnosticEvidence } from "../session/diagnosticEvidence";

export interface DiagnosticReportActionsProps {
  error: EngineError | null;
  thumbnailsFailed: { code: string; message: string } | null;
  device: DeviceInfo | null;
  status: ScannerStatus | null;
  thumbnails: Record<number, Thumbnail>;
  transportEvidence?: DiagnosticEvidence | null;
  unavailableEvidenceReason?: string | null;
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
  transportEvidence = null,
  unavailableEvidenceReason = null,
}: DiagnosticReportActionsProps) {
  const { status: copyStatus, copy: copyToClipboard } = useClipboardCopy();
  const [isSavingBundle, setIsSavingBundle] = useState(false);
  const [didSaveBundle, setDidSaveBundle] = useState(false);
  const [showBundleOptions, setShowBundleOptions] = useState(false);
  const [includePreview, setIncludePreview] = useState(false);
  const [bundlePreviewCandidate, setBundlePreviewCandidate] =
    useState<PreviewRasterCandidate | null>(null);

  // thumbnailsFailed takes precedence over a typed request rejection,
  // mirroring HardwareErrorPanel's own branch order.
  const errorCode = thumbnailsFailed?.code ?? error?.code ?? null;
  const errorMessage = thumbnailsFailed?.message ?? error?.message ?? null;
  const previewFrameIndex = bundlePreviewCandidate?.frameIndex;
  const previewAvailable = Boolean(bundlePreviewCandidate?.imagePath);

  useEffect(() => {
    if (errorCode === null) return;
    diagnosticTimeline.record("error.surfaced", { code: errorCode });
  }, [errorCode, error, thumbnailsFailed]);

  useEffect(() => {
    setShowBundleOptions(false);
    setIncludePreview(false);
    setBundlePreviewCandidate(null);
  }, [errorCode, error, thumbnailsFailed]);

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
      sensitiveValues: device?.deviceId ? [device.deviceId] : [],
    };
  };

  const handleCopyReport = async (): Promise<void> => {
    const text = buildErrorReportText(await buildReportContext());
    // navigator.clipboard only exists in secure contexts; the hook reports
    // unavailability on the button instead of dying on an unhandled
    // rejection (the pre-fix Windows behavior).
    await copyToClipboard(text);
  };

  const handleSaveDiagnosticBundle = async (): Promise<void> => {
    const consentedPreview = includePreview && previewAvailable;
    setIsSavingBundle(true);
    try {
      const reportText = buildErrorReportText(await buildReportContext());
      const { raster, unavailableReason } = consentedPreview
        ? await resolveDiagnosticBundleRasterCandidate(
            bundlePreviewCandidate,
            readPreviewRasterBytes,
          )
        : { raster: null, unavailableReason: null };
      const zipBytes = buildDiagnosticBundleZip({
        diagnosticsJsonl: diagnosticTimeline.toJsonl(),
        reportText,
        previewRaster: raster,
        unavailableRasterReason: unavailableReason,
        includePreview: consentedPreview,
        previewFrameIndex,
        transportEvidence,
        unavailableEvidenceReason,
        sensitiveValues: device?.deviceId ? [device.deviceId] : [],
      });

      const saved = await saveDiagnosticBundleFile(
        `ScanStudio-Diagnostics-${timestampForFilename()}.zip`,
        zipBytes,
      );
      if (!saved) return;
      setDidSaveBundle(true);
      setTimeout(() => setDidSaveBundle(false), 1500);
    } finally {
      setIsSavingBundle(false);
      setShowBundleOptions(false);
      setIncludePreview(false);
      setBundlePreviewCandidate(null);
    }
  };

  return (
    <div data-testid="diagnostic-report-actions">
      <button type="button" onClick={() => void handleCopyReport()} data-testid="copy-report">
        {copyStatus === "copied"
          ? "Copied"
          : copyStatus === "unavailable"
            ? "Clipboard unavailable"
            : "Copy Report"}
      </button>
      <button
        type="button"
        onClick={() => {
          setIncludePreview(false);
          setBundlePreviewCandidate(selectDiagnosticBundleRasterCandidate(thumbnails));
          setShowBundleOptions(true);
        }}
        disabled={isSavingBundle}
        data-testid="save-diagnostic-bundle"
      >
        {didSaveBundle ? "Saved" : "Save Diagnostic Bundle…"}
      </button>
      {showBundleOptions && (
        <div data-testid="diagnostic-bundle-options">
          <p data-testid="diagnostic-bundle-inventory">
            Bundle files: diagnostics.jsonl, manifest.txt, report.txt
            {transportEvidence ? ", evidence-v1.json" : ""}.
            {bundlePreviewCandidate !== null
              ? ` Optional candidate currently excluded: one validated preview.png, preview.jpg, or preview.tif for Frame ${bundlePreviewCandidate.frameIndex}.`
              : " No optional film-content candidate exists."}
          </p>
          {previewAvailable && (
            <label data-testid="include-film-preview-label">
              <input
                type="checkbox"
                checked={includePreview}
                onChange={(event) => setIncludePreview(event.currentTarget.checked)}
                data-testid="include-film-preview"
              />
              Include film-content preview for Frame {previewFrameIndex}
            </label>
          )}
          <p>Film imagery is excluded by default. Consent applies to this export only.</p>
          <button
            type="button"
            disabled={isSavingBundle}
            onClick={() => void handleSaveDiagnosticBundle()}
            data-testid="confirm-save-diagnostic-bundle"
          >
            {isSavingBundle ? "Saving…" : "Save bundle"}
          </button>
          <button
            type="button"
            disabled={isSavingBundle}
            onClick={() => {
              setShowBundleOptions(false);
              setIncludePreview(false);
              setBundlePreviewCandidate(null);
            }}
          >
            Cancel
          </button>
        </div>
      )}
    </div>
  );
}

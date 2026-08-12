// Per-frame metadata override editor + ExifTool preview/apply panel (07-01
// Task 2). Pure presentational component: props only. The override toggle
// mirrors the other per-frame overrides' whole-object-swap semantics -- the
// editor reuses MetadataPanel's field set (including PartialDateEditor) and
// onSetOverride always receives the COMPLETE MetadataSet; turning the toggle
// off after a value exists sends null (revert to the roll-wide default).
//
// The ExifTool panel shows the EXACT, complete argument array (one per line,
// copyable) before anything runs (CONTEXT decision 1: "that transparency is
// the feature"), then renders the resolved exitCode/stdout/stderr verbatim --
// never a friendlier invented success message (threat T-07-04).

import { useEffect, useState } from "react";
import type {
  ApplyMetadataResult,
  ExifToolDetection,
  MetadataSet,
  PreviewMetadataCommandResult,
} from "../session/wire/types";
import MetadataPanel from "./MetadataPanel";
import styles from "./Metadata.module.css";

export interface FrameMetadataOverrideProps {
  frameIndex: number;
  effectiveMetadata: MetadataSet;
  override: MetadataSet | null;
  onSetOverride: (next: MetadataSet | null) => void;
  exifToolDetection: ExifToolDetection | null;
  metadataPreview: PreviewMetadataCommandResult | null;
  onPreviewCommand: () => void;
  onApply: () => Promise<ApplyMetadataResult | null>;
}

function readonlyLines(metadata: MetadataSet): Array<[string, string]> {
  const lines: Array<[string, string]> = [];
  if (metadata.camera !== undefined) lines.push(["Camera", metadata.camera]);
  if (metadata.lens !== undefined) lines.push(["Lens", metadata.lens]);
  if (metadata.filmStock !== undefined) lines.push(["Film stock", metadata.filmStock]);
  if (metadata.process !== undefined) lines.push(["Process", metadata.process]);
  if (metadata.iso !== undefined) lines.push(["ISO", String(metadata.iso)]);
  if (metadata.date !== undefined) {
    lines.push(["Date", JSON.stringify(metadata.date)]);
  }
  if (metadata.location !== undefined) lines.push(["Location", metadata.location]);
  if (metadata.photographer !== undefined) lines.push(["Photographer", metadata.photographer]);
  if (metadata.copyright !== undefined) lines.push(["Copyright", metadata.copyright]);
  if (metadata.rollId !== undefined) lines.push(["Roll ID", metadata.rollId]);
  if (metadata.notes !== undefined) lines.push(["Notes", metadata.notes]);
  const keywords = metadata.keywords ?? [];
  if (keywords.length > 0) lines.push(["Keywords", keywords.join(", ")]);
  return lines;
}

export default function FrameMetadataOverride({
  frameIndex,
  effectiveMetadata,
  override,
  onSetOverride,
  exifToolDetection,
  metadataPreview,
  onPreviewCommand,
  onApply,
}: FrameMetadataOverrideProps) {
  const frameHasOverride = override !== null;
  const [enabled, setEnabled] = useState<boolean>(frameHasOverride);
  const [draft, setDraft] = useState<MetadataSet>(() =>
    override !== null ? { ...override } : { ...effectiveMetadata },
  );
  const [applyBusy, setApplyBusy] = useState(false);
  const [applyResult, setApplyResult] = useState<ApplyMetadataResult | null>(null);
  const [previewInvalidated, setPreviewInvalidated] = useState(false);

  useEffect(() => {
    // A new preview object is the only event that re-authorizes Apply after
    // a metadata mutation. Never re-enable against the old displayed array.
    setPreviewInvalidated(false);
  }, [metadataPreview]);

  const invalidatePreview = (): void => {
    setPreviewInvalidated(true);
    setApplyResult(null);
  };

  const handleToggle = (): void => {
    if (enabled) {
      // Turning the override off after it had a value reverts to the
      // roll-wide default (whole-object null, never a cleared diff).
      if (override !== null) {
        invalidatePreview();
        onSetOverride(null);
      }
      setEnabled(false);
    } else {
      setDraft(override !== null ? { ...override } : { ...effectiveMetadata });
      // Seeding a fresh editor must also discard any prior apply result from
      // an earlier frame/editor lifecycle (keyed by frameIndex in the parent).
      setApplyResult(null);
      setEnabled(true);
    }
  };

  const exifToolAvailable =
    exifToolDetection !== null && exifToolDetection.available === true;
  const authoritativePreview = previewInvalidated ? null : metadataPreview;
  const canApply =
    authoritativePreview !== null && authoritativePreview.targets.length > 0 && !applyBusy;

  const runApply = async (): Promise<void> => {
    setApplyBusy(true);
    try {
      setApplyResult(await onApply());
    } finally {
      setApplyBusy(false);
    }
  };

  const copyArguments = async (): Promise<void> => {
    if (authoritativePreview === null || authoritativePreview.arguments.length === 0) return;
    try {
      await navigator.clipboard?.writeText(authoritativePreview.arguments.join("\n"));
    } catch {
      // Clipboard unavailable (non-secure context / jsdom): the block is
      // still fully readable and the copy button is purely additive.
    }
  };

  return (
    <div className={styles.overrideEditor} data-testid="frame-metadata-override">
      <div className={styles.sectionHeader}>
        <h3 className={styles.sectionTitle}>Frame {frameIndex} metadata</h3>
      </div>

      <div className={styles.startRow}>
        <label className={styles.radioRow}>
          <input
            className={styles.checkboxInput}
            type="checkbox"
            data-testid="override-metadata-toggle"
            checked={enabled}
            onChange={handleToggle}
          />
          <span className={styles.radioLabel}>Override this frame&rsquo;s metadata</span>
        </label>
        {frameHasOverride && (
          <button
            type="button"
            className={styles.dangerButton}
            data-testid="clear-metadata-override"
            onClick={() => {
              invalidatePreview();
              onSetOverride(null);
            }}
          >
            Revert to roll default
          </button>
        )}
      </div>

      {enabled ? (
        <MetadataPanel
          rollMetadata={draft}
          onSave={(next) => {
            setDraft({ ...next });
            invalidatePreview();
            onSetOverride(next);
          }}
          exifToolDetection={exifToolDetection}
          // Detection is owned at the composition level (this panel receives
          // the result); within the override editor a no-op keeps the shared
          // field editor attached without double-probing.
          onDetectExifTool={() => undefined}
        />
      ) : (
        <ul className={styles.readonlyList} data-testid="effective-metadata-readonly">
          {readonlyLines(effectiveMetadata).map(([label, value]) => (
            <li key={label}>
              <span className={styles.fieldLabel}>{label}: </span>
              <span className={styles.fieldValue}>{value}</span>
            </li>
          ))}
          {readonlyLines(effectiveMetadata).length === 0 && (
            <li className={styles.fieldValue}>(roll default has no metadata set)</li>
          )}
        </ul>
      )}

      <div className={styles.section}>
        <div className={styles.sectionHeader}>
          <h3 className={styles.sectionTitle}>ExifTool</h3>
        </div>
        <div className={styles.sectionBody}>
          <div className={styles.startRow}>
            <button
              type="button"
              className={styles.controlButton}
              data-testid="preview-command"
              disabled={!exifToolAvailable}
              onClick={onPreviewCommand}
            >
              Preview Command
            </button>
            <button
              type="button"
              className={styles.primaryButton}
              data-testid="apply-metadata"
              disabled={!canApply}
              onClick={() => void runApply()}
            >
              Apply Metadata
            </button>
          </div>
          {authoritativePreview !== null && (
            <div>
              <div className={styles.startRow}>
                <span className={styles.fieldLabel} data-testid="argument-count">
                  Arguments ({authoritativePreview.arguments.length})
                </span>
                <button
                  type="button"
                  className={styles.controlButton}
                  data-testid="copy-arguments"
                  disabled={authoritativePreview.arguments.length === 0}
                  onClick={() => void copyArguments()}
                >
                  Copy
                </button>
              </div>
              <pre className={styles.argBlock} data-testid="exiftool-arguments">
                {authoritativePreview.arguments.map((argument, index) => (
                  <span className={styles.argLine} key={`${index}-${argument}`}>
                    {argument}
                  </span>
                ))}
              </pre>
            </div>
          )}
          {applyResult !== null && (
            <div className={styles.resultBlock} data-testid="exiftool-apply-result">
              <p className={styles.fieldValue} data-testid="exiftool-exit-code">
                Exit code: {applyResult.exitCode}
              </p>
              <span className={styles.fieldLabel}>stdout</span>
              <pre className={styles.resultPre} data-testid="exiftool-stdout">
                {applyResult.stdout}
              </pre>
              <span className={styles.fieldLabel}>stderr</span>
              <pre className={styles.resultPre} data-testid="exiftool-stderr">
                {applyResult.stderr}
              </pre>
              <span className={styles.fieldLabel}>
                Targets: {applyResult.targets.join(", ") || "(none)"}
              </span>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

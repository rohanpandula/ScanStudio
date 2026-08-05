// Roll-wide metadata editor (07-01 Task 2). Pure presentational component:
// props only, no store/context import. Holds its own draft copy seeded from
// the rollMetadata prop and calls onSave with the COMPLETE MetadataSet on
// Save -- a whole-object swap, never a partial diff. Blank free-text fields
// are omitted from the wire payload (absent, not empty-string) so the
// engine's ExifTool argument builder treats a deliberate clear correctly.
// ExifTool availability is surfaced as a status line; the component requests
// a detection exactly once on mount when none is provided (mirrors
// BatchInspectorView's .task { await sessionModel.detectExifTool() }).

import { useEffect, useState } from "react";
import type { ExifToolDetection, MetadataSet, PartialDate } from "../session/wire/types";
import PartialDateEditor from "./PartialDateEditor";
import styles from "./Metadata.module.css";

export interface MetadataPanelProps {
  rollMetadata: MetadataSet;
  onSave: (next: MetadataSet) => void;
  exifToolDetection: ExifToolDetection | null;
  onDetectExifTool: () => void;
}

interface Draft {
  camera: string;
  lens: string;
  filmStock: string;
  iso: string;
  date: PartialDate | null;
  location: string;
  photographer: string;
  copyright: string;
  rollId: string;
  notes: string;
  keywords: string;
}

function draftFromMetadata(metadata: MetadataSet): Draft {
  return {
    camera: metadata.camera ?? "",
    lens: metadata.lens ?? "",
    filmStock: metadata.filmStock ?? "",
    iso: metadata.iso === undefined ? "" : String(metadata.iso),
    date: metadata.date ?? null,
    location: metadata.location ?? "",
    photographer: metadata.photographer ?? "",
    copyright: metadata.copyright ?? "",
    rollId: metadata.rollId ?? "",
    notes: metadata.notes ?? "",
    keywords: (metadata.keywords ?? []).join(", "),
  };
}

function splitKeywords(raw: string): string[] {
  const trimmed = raw.trim();
  if (trimmed === "") return [];
  return trimmed
    .split(",")
    .map((keyword) => keyword.trim())
    .filter((keyword) => keyword !== "");
}

function exifToolStatus(detection: ExifToolDetection | null | undefined): string {
  if (detection == null) return "Checking for ExifTool…";
  if (detection.available) {
    return `ExifTool available: ${detection.path ?? "unknown path"} (${detection.version ?? "unknown version"})`;
  }
  return "ExifTool is not available on this machine.";
}

export default function MetadataPanel({
  rollMetadata,
  onSave,
  exifToolDetection,
  onDetectExifTool,
}: MetadataPanelProps) {
  const [draft, setDraft] = useState<Draft>(() => draftFromMetadata(rollMetadata));

  // Adopt an externally-changed rollMetadata (a project reload, a revert)
  // into the editor as a full-copy replace, never a merge into user edits.
  // Content-keyed so unrelated re-renders never wipe in-progress editing.
  const metadataKey = JSON.stringify(rollMetadata ?? null);
  useEffect(() => {
    setDraft(draftFromMetadata(rollMetadata));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [metadataKey]);

  // Request an ExifTool detection exactly once on mount when none is known.
  const detectRef = { current: onDetectExifTool };
  detectRef.current = onDetectExifTool;
  useEffect(() => {
    if (exifToolDetection == null) {
      detectRef.current();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const save = (): void => {
    const next: MetadataSet = { keywords: splitKeywords(draft.keywords) };
    if (draft.camera !== "") next.camera = draft.camera;
    if (draft.lens !== "") next.lens = draft.lens;
    if (draft.filmStock !== "") next.filmStock = draft.filmStock;
    const iso = Number(draft.iso);
    if (draft.iso !== "" && Number.isFinite(iso)) next.iso = iso;
    if (draft.date !== null) next.date = draft.date;
    if (draft.location !== "") next.location = draft.location;
    if (draft.photographer !== "") next.photographer = draft.photographer;
    if (draft.copyright !== "") next.copyright = draft.copyright;
    if (draft.rollId !== "") next.rollId = draft.rollId;
    if (draft.notes !== "") next.notes = draft.notes;
    onSave(next);
  };

  const setField = <K extends keyof Draft>(key: K, value: Draft[K]): void => {
    setDraft((previous) => ({ ...previous, [key]: value }));
  };

  return (
    <div data-testid="metadata-panel">
      <div className={styles.section}>
        <div className={styles.sectionHeader}>
          <h3 className={styles.sectionTitle}>Roll metadata</h3>
        </div>
        <div className={styles.sectionBody}>
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel} htmlFor="metadata-camera">
              Camera
            </label>
            <input
              id="metadata-camera"
              className={styles.textInput}
              type="text"
              data-testid="metadata-camera"
              value={draft.camera}
              onChange={(event) => setField("camera", event.target.value)}
            />
          </div>
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel} htmlFor="metadata-lens">
              Lens
            </label>
            <input
              id="metadata-lens"
              className={styles.textInput}
              type="text"
              data-testid="metadata-lens"
              value={draft.lens}
              onChange={(event) => setField("lens", event.target.value)}
            />
          </div>
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel} htmlFor="metadata-filmstock">
              Film stock
            </label>
            <input
              id="metadata-filmstock"
              className={styles.textInput}
              type="text"
              data-testid="metadata-filmstock"
              value={draft.filmStock}
              onChange={(event) => setField("filmStock", event.target.value)}
            />
          </div>
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel} htmlFor="metadata-iso">
              ISO
            </label>
            <input
              id="metadata-iso"
              className={styles.numberInput}
              type="number"
              min={1}
              data-testid="metadata-iso"
              value={draft.iso}
              onChange={(event) => setField("iso", event.target.value)}
            />
          </div>
          <div className={styles.fieldRow}>
            <span className={styles.fieldLabel}>Date</span>
            <PartialDateEditor
              value={draft.date}
              onChange={(next) => setField("date", next)}
            />
          </div>
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel} htmlFor="metadata-location">
              Location
            </label>
            <input
              id="metadata-location"
              className={styles.textInput}
              type="text"
              data-testid="metadata-location"
              value={draft.location}
              onChange={(event) => setField("location", event.target.value)}
            />
          </div>
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel} htmlFor="metadata-photographer">
              Photographer
            </label>
            <input
              id="metadata-photographer"
              className={styles.textInput}
              type="text"
              data-testid="metadata-photographer"
              value={draft.photographer}
              onChange={(event) => setField("photographer", event.target.value)}
            />
          </div>
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel} htmlFor="metadata-copyright">
              Copyright
            </label>
            <input
              id="metadata-copyright"
              className={styles.textInput}
              type="text"
              data-testid="metadata-copyright"
              value={draft.copyright}
              onChange={(event) => setField("copyright", event.target.value)}
            />
          </div>
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel} htmlFor="metadata-rollid">
              Roll ID
            </label>
            <input
              id="metadata-rollid"
              className={styles.textInput}
              type="text"
              data-testid="metadata-rollid"
              value={draft.rollId}
              onChange={(event) => setField("rollId", event.target.value)}
            />
          </div>
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel} htmlFor="metadata-notes">
              Notes
            </label>
            <textarea
              id="metadata-notes"
              className={styles.notesInput}
              rows={2}
              data-testid="metadata-notes"
              value={draft.notes}
              onChange={(event) => setField("notes", event.target.value)}
            />
          </div>
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel} htmlFor="metadata-keywords">
              Keywords
            </label>
            <input
              id="metadata-keywords"
              className={styles.textInput}
              type="text"
              data-testid="metadata-keywords"
              placeholder="comma-separated"
              value={draft.keywords}
              onChange={(event) => setField("keywords", event.target.value)}
            />
          </div>
          <div className={styles.startRow}>
            <button
              type="button"
              className={styles.primaryButton}
              data-testid="metadata-save"
              onClick={save}
            >
              Save metadata
            </button>
          </div>
          <div>
            <span className={styles.fieldLabel}>ExifTool</span>
            <p className={styles.fieldValue} data-testid="exiftool-status">
              {exifToolStatus(exifToolDetection)}
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}

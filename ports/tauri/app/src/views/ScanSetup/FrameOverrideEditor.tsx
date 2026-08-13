import { useRef, useState } from "react";
import type { FilmProcess, ResolvedCaptureRecipe } from "../../session/store/session";
import type {
  CaptureRecipe,
  OutputRecipe,
  ProcessingRecipe,
  ScanProject,
} from "../../session/wire/types";
import { sessionStore } from "../../session";
import CaptureRecipeForm from "../ScanSetup/CaptureRecipeForm";
import ProcessingRecipeForm from "../ScanSetup/ProcessingRecipeForm";
import OutputRecipeForm from "../ScanSetup/OutputRecipeForm";
import styles from "./ScanSetup.module.css";

export interface FrameOverrideEditorProps {
  frameIndex: number;
  filmProcess: FilmProcess;
  // Roll-wide current recipes (resolved) that seed a brand-new override.
  rollCapture: ResolvedCaptureRecipe;
  rollProcessing?: ProcessingRecipe;
  rollOutput: OutputRecipe;
  // Device-aware multisamplePasses options (session/store/session.ts's
  // multisampleOptionsForDevice), forwarded verbatim to this editor's own
  // per-frame CaptureRecipeForm so a frame override picker never offers a
  // count the connected device's scan.start gate would reject either.
  multisampleOptions: readonly number[];
  // The active project's frame set — used to read any existing override and
  // to detect a whole-object-swap save (never a merged payload).
  project: ScanProject | null;
}

interface OverrideSection {
  capture: ResolvedCaptureRecipe;
  processing?: ProcessingRecipe;
  output: OutputRecipe;
}

type SectionKey = "capture" | "processing" | "output";
const SECTIONS: SectionKey[] = ["capture", "processing", "output"];

export default function FrameOverrideEditor({
  frameIndex,
  filmProcess,
  rollCapture,
  rollProcessing,
  rollOutput,
  multisampleOptions,
  project,
}: FrameOverrideEditorProps) {
  const frame = project?.frames.find((f) => f.index === frameIndex) ?? null;
  const [openSections, setOpenSections] = useState<Set<SectionKey>>(new Set());
  // Draft copies, seeded the first time a section opens. Saving always sends
  // the full draft object -- never a diff merged onto stale roll values.
  const [drafts, setDrafts] = useState<OverrideSection>(() => ({
    capture: { ...rollCapture, ...(frame?.captureOverride ?? {}) },
    processing: frame?.processingOverride ?? (rollProcessing ? { ...rollProcessing } : undefined),
    output: frame?.outputOverride ?? { ...rollOutput },
  }));
  const draftsRef = useRef(drafts);
  draftsRef.current = drafts;
  const [saving, setSaving] = useState<SectionKey | null>(null);

  const captureOverride = frame?.captureOverride;
  const processingOverride = frame?.processingOverride;
  const outputOverride = frame?.outputOverride;

  const toggleSection = (key: SectionKey): void => {
    setOpenSections((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
    // When opening, seed the draft from a full copy of the roll-wide recipe (or
    // the existing override if set) so every field is present and editable.
    if (!openSections.has(key)) {
      setDrafts((prev) => ({
        ...prev,
        [key]:
          key === "capture"
            ? { ...(captureOverride ?? rollCapture) }
            : key === "processing"
              ? { ...(processingOverride ?? rollProcessing ?? (prev.processing ?? rollProcessing)) }
              : { ...(outputOverride ?? rollOutput) },
      }));
    }
  };

  const save = async (key: SectionKey): Promise<void> => {
    setSaving(key);
    try {
      const draft = key === "capture" ? draftsRef.current.capture : undefined;
      const processing = key === "processing" ? draftsRef.current.processing : undefined;
      const output = key === "output" ? draftsRef.current.output : undefined;
      if (key === "capture") {
        await sessionStore.setFrameCaptureOverride(frameIndex, draft as CaptureRecipe);
      } else if (key === "processing") {
        await sessionStore.setFrameProcessingOverride(frameIndex, processing as ProcessingRecipe);
      } else {
        await sessionStore.setFrameOutputOverride(frameIndex, output as OutputRecipe);
      }
      setOpenSections((prev) => {
        const next = new Set(prev);
        next.delete(key);
        return next;
      });
    } finally {
      setSaving(null);
    }
  };

  const clear = async (key: SectionKey): Promise<void> => {
    setSaving(key);
    try {
      if (key === "capture") await sessionStore.setFrameCaptureOverride(frameIndex, null);
      else if (key === "processing") await sessionStore.setFrameProcessingOverride(frameIndex, null);
      else await sessionStore.setFrameOutputOverride(frameIndex, null);
    } finally {
      setSaving(null);
    }
  };

  const isSet = (key: SectionKey): boolean =>
    key === "capture" ? captureOverride !== undefined : key === "processing" ? processingOverride !== undefined : outputOverride !== undefined;

  return (
    <div className={styles.overrideEditor} data-testid="frame-override-editor">
      <div className={styles.sectionHeader}>
        <h3 className={styles.sectionTitle}>Per-frame overrides — frame {frameIndex}</h3>
      </div>
      {SECTIONS.map((key) => {
        const open = openSections.has(key);
        const set = isSet(key);
        return (
          <div key={key} data-testid={`override-section-${key}`}>
            <div className={styles.startRow}>
              <button
                type="button"
                className={styles.controlButton}
                data-testid={`toggle-override-${key}`}
                onClick={() => void toggleSection(key)}
              >
                {open ? "Close" : set ? "Edit override" : `Override ${key}`}
              </button>
              {set && (
                <button
                  type="button"
                  className={styles.dangerButton}
                  data-testid={`clear-override-${key}`}
                  disabled={saving !== null}
                  onClick={() => void clear(key)}
                >
                  Revert to roll default
                </button>
              )}
            </div>
            {open && (
              <div className={styles.sectionBody}>
                {key === "capture" && (
                  <CaptureRecipeForm
                    capture={drafts.capture}
                    filmProcess={filmProcess}
                    multisampleOptions={multisampleOptions}
                    onChange={(next) => setDrafts((d) => ({ ...d, capture: next }))}
                  />
                )}
                {key === "processing" && drafts.processing !== undefined && (
                  <ProcessingRecipeForm
                    processing={drafts.processing}
                    filmProcess={filmProcess}
                    onChange={(next) => setDrafts((d) => ({ ...d, processing: next }))}
                  />
                )}
                {key === "output" && (
                  <OutputRecipeForm
                    output={drafts.output}
                    onChange={(next) => setDrafts((d) => ({ ...d, output: next }))}
                  />
                )}
                <button
                  type="button"
                  className={styles.primaryButton}
                  data-testid={`save-override-${key}`}
                  disabled={saving !== null}
                  onClick={() => void save(key)}
                >
                  Save {key} override
                </button>
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

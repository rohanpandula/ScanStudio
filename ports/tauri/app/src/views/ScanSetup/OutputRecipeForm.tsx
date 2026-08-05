import { open } from "@tauri-apps/plugin-dialog";
import type { OutputRecipe } from "../../session/wire/types";
import styles from "./ScanSetup.module.css";

export interface OutputRecipeFormProps {
  output: OutputRecipe;
  onChange: (next: OutputRecipe) => void;
}

// Pure template-preview helper (tested directly): replaces the first run of
// `#` characters with the frame number zero-padded to that run's width, and
// never mutates the stored template string.
export function previewFilename(
  template: string,
  frameIndex: number,
  width?: number,
): string {
  const match = /#+/.exec(template);
  if (!match) return template;
  const runLength = width ?? match[0].length;
  const padded = String(frameIndex).padStart(runLength, "0");
  return template.slice(0, match.index) + padded + template.slice(match.index + match[0].length);
}

const POSITIVE_FORMATS: Array<PositiveRecipeSection["fileFormat"]> = ["tiff", "jpeg"];
const COLOR_PROFILES: Array<PositiveRecipeSection["colorProfile"]> = [
  "adobeRgb1998",
  "sRgb",
  "proPhotoRgb",
];
const PREVIEW_FORMATS: Array<PreviewRecipeSection["fileFormat"]> = ["tiff", "jpeg"];

type PositiveRecipeSection = OutputRecipe["positive"];
type PreviewRecipeSection = OutputRecipe["preview"];

function DestinationField({
  label,
  value,
  onChange,
}: {
  label: string;
  value: string;
  onChange: (next: string) => void;
}) {
  const pick = async (): Promise<void> => {
    const chosen = await open({
      directory: true,
      multiple: false,
    });
    // Set the field's value to the returned path string only; nothing else
    // is done with it (destinations are opaque strings passed through).
    if (typeof chosen === "string" && chosen.length > 0) {
      onChange(chosen);
    }
  };
  return (
    <div className={styles.fieldRow}>
      <label className={styles.fieldLabel}>{label}</label>
      <div className={styles.startRow}>
        <input
          className={styles.textInput}
          type="text"
          data-testid={`${label}-destination`}
          value={value}
          onChange={(event) => onChange(event.target.value)}
        />
        <button
          type="button"
          className={styles.controlButton}
          data-testid={`${label}-pick-destination`}
          onClick={() => void pick()}
        >
          Choose…
        </button>
      </div>
    </div>
  );
}

export default function OutputRecipeForm({ output, onChange }: OutputRecipeFormProps) {
  const patchArchive = (patch: Partial<OutputRecipe["archive"]>): void => {
    onChange({ ...output, archive: { ...output.archive, ...patch } });
  };
  const patchPositive = (patch: Partial<PositiveRecipeSection>): void => {
    onChange({ ...output, positive: { ...output.positive, ...patch } });
  };
  const patchPreview = (patch: Partial<PreviewRecipeSection>): void => {
    onChange({ ...output, preview: { ...output.preview, ...patch } });
  };

  return (
    <div className={styles.section} data-testid="output-recipe-form">
      <div className={styles.sectionHeader}>
        <h3 className={styles.sectionTitle}>Output</h3>
      </div>
      <div className={styles.sectionBody}>
        <div className={styles.checkboxRow}>
          <input
            id="auto-crop"
            className={styles.checkboxInput}
            type="checkbox"
            data-testid="output-auto-crop"
            checked={output.autoCrop ?? false}
            onChange={(event) => onChange({ ...output, autoCrop: event.target.checked })}
          />
          <label className={styles.fieldLabel} htmlFor="auto-crop">
            Automatically crop finished images
          </label>
        </div>
        <p className={styles.templatePreview} data-testid="auto-crop-help">
          Crops each Positive and Preview independently. The archive master stays full-frame.
        </p>

        {/* ------------------------------------------------------------------ */}
        {/* Archive section (create-only semantics; fullCapturePackage gated   */}
        {/* on archive.enabled)                                               */}
        {/* ------------------------------------------------------------------ */}
        <div data-testid="archive-section">
          <div className={styles.checkboxRow}>
            <input
              id="archive-enabled"
              className={styles.checkboxInput}
              type="checkbox"
              checked={output.archive.enabled !== false}
              onChange={(event) =>
                patchArchive({
                  enabled: event.target.checked,
                  // Disabling archive forces fullCapturePackage off as well.
                  fullCapturePackage: event.target.checked ? output.archive.fullCapturePackage : false,
                })
              }
            />
            <label className={styles.fieldLabel} htmlFor="archive-enabled">
              Archive (create-only)
            </label>
          </div>
          {output.archive.enabled !== false && (
            <div className={styles.sectionBody}>
              <DestinationField
                label="Archive destination"
                value={output.archive.destination}
                onChange={(destination) => patchArchive({ destination })}
              />
              <div className={styles.fieldRow}>
                <label className={styles.fieldLabel} htmlFor="archive-template">
                  Filename template
                </label>
                <input
                  id="archive-template"
                  className={styles.textInput}
                  type="text"
                  data-testid="archive-filename-template"
                  value={output.archive.filenameTemplate}
                  onChange={(event) => patchArchive({ filenameTemplate: event.target.value })}
                />
                <p className={styles.templatePreview} data-testid="archive-template-preview">
                  e.g. <strong>{previewFilename(output.archive.filenameTemplate, 7)}</strong>
                </p>
              </div>
              <div className={styles.checkboxRow}>
                <input
                  id="archive-full-package"
                  className={styles.checkboxInput}
                  type="checkbox"
                  data-testid="archive-full-capture-package"
                  checked={output.archive.fullCapturePackage !== false}
                  onChange={(event) => patchArchive({ fullCapturePackage: event.target.checked })}
                />
                <label className={styles.fieldLabel} htmlFor="archive-full-package">
                  Full capture package
                </label>
              </div>
            </div>
          )}
        </div>

        {/* ------------------------------------------------------------------ */}
        {/* Positive section                                                   */}
        {/* ------------------------------------------------------------------ */}
        <div data-testid="positive-section">
          <div className={styles.checkboxRow}>
            <input
              id="positive-enabled"
              className={styles.checkboxInput}
              type="checkbox"
              checked={output.positive.enabled}
              onChange={(event) => patchPositive({ enabled: event.target.checked })}
            />
            <label className={styles.fieldLabel} htmlFor="positive-enabled">
              Positive derivative
            </label>
          </div>
          {output.positive.enabled && (
            <div className={styles.sectionBody}>
              <DestinationField
                label="Positive destination"
                value={output.positive.destination}
                onChange={(destination) => patchPositive({ destination })}
              />
              <div className={styles.fieldRow}>
                <label className={styles.fieldLabel} htmlFor="positive-format">
                  Format
                </label>
                <select
                  id="positive-format"
                  className={styles.selectInput}
                  data-testid="positive-format"
                  value={output.positive.fileFormat}
                  onChange={(event) =>
                    patchPositive({ fileFormat: event.target.value as PositiveRecipeSection["fileFormat"] })
                  }
                >
                  {POSITIVE_FORMATS.map((format) => (
                    <option key={format} value={format}>
                      {format}
                    </option>
                  ))}
                </select>
              </div>
              <div className={styles.fieldRow}>
                <label className={styles.fieldLabel} htmlFor="positive-color-profile">
                  Color profile
                </label>
                <select
                  id="positive-color-profile"
                  className={styles.selectInput}
                  data-testid="positive-color-profile"
                  value={output.positive.colorProfile}
                  onChange={(event) =>
                    patchPositive({ colorProfile: event.target.value as PositiveRecipeSection["colorProfile"] })
                  }
                >
                  {COLOR_PROFILES.map((profile) => (
                    <option key={profile} value={profile}>
                      {profile}
                    </option>
                  ))}
                </select>
              </div>
              <div className={styles.fieldRow}>
                <label className={styles.fieldLabel} htmlFor="positive-template">
                  Filename template
                </label>
                <input
                  id="positive-template"
                  className={styles.textInput}
                  type="text"
                  data-testid="positive-filename-template"
                  value={output.positive.filenameTemplate}
                  onChange={(event) => patchPositive({ filenameTemplate: event.target.value })}
                />
                <p className={styles.templatePreview} data-testid="positive-template-preview">
                  e.g. <strong>{previewFilename(output.positive.filenameTemplate, 7)}</strong>
                </p>
              </div>
            </div>
          )}
        </div>

        {/* ------------------------------------------------------------------ */}
        {/* Preview section                                                    */}
        {/* ------------------------------------------------------------------ */}
        <div data-testid="preview-section">
          <div className={styles.checkboxRow}>
            <input
              id="preview-enabled"
              className={styles.checkboxInput}
              type="checkbox"
              checked={output.preview.enabled}
              onChange={(event) => patchPreview({ enabled: event.target.checked })}
            />
            <label className={styles.fieldLabel} htmlFor="preview-enabled">
              Preview derivative
            </label>
          </div>
          {output.preview.enabled && (
            <div className={styles.sectionBody}>
              <DestinationField
                label="Preview destination"
                value={output.preview.destination}
                onChange={(destination) => patchPreview({ destination })}
              />
              <div className={styles.fieldRow}>
                <label className={styles.fieldLabel} htmlFor="preview-format">
                  Format
                </label>
                <select
                  id="preview-format"
                  className={styles.selectInput}
                  data-testid="preview-format"
                  value={output.preview.fileFormat}
                  onChange={(event) =>
                    patchPreview({ fileFormat: event.target.value as PreviewRecipeSection["fileFormat"] })
                  }
                >
                  {PREVIEW_FORMATS.map((format) => (
                    <option key={format} value={format}>
                      {format}
                    </option>
                  ))}
                </select>
              </div>
              <div className={styles.fieldRow}>
                <label className={styles.fieldLabel} htmlFor="preview-max-long-edge">
                  Max long edge (px)
                </label>
                <input
                  id="preview-max-long-edge"
                  className={`${styles.numberInput} ${styles.fixedWidth}`}
                  type="number"
                  data-testid="preview-max-long-edge"
                  min={1}
                  value={output.preview.maxLongEdgePx}
                  onChange={(event) => patchPreview({ maxLongEdgePx: Number(event.target.value) })}
                />
              </div>
              <div className={styles.fieldRow}>
                <label className={styles.fieldLabel} htmlFor="preview-template">
                  Filename template
                </label>
                <input
                  id="preview-template"
                  className={styles.textInput}
                  type="text"
                  data-testid="preview-filename-template"
                  value={output.preview.filenameTemplate}
                  onChange={(event) => patchPreview({ filenameTemplate: event.target.value })}
                />
                <p className={styles.templatePreview} data-testid="preview-template-preview">
                  e.g. <strong>{previewFilename(output.preview.filenameTemplate, 7)}</strong>
                </p>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

import type { FilmProcess } from "../../session/store/session";
import type { ProcessingRecipe } from "../../session/wire/types";
import styles from "./ScanSetup.module.css";

export interface ProcessingRecipeFormProps {
  processing: ProcessingRecipe;
  // Authoritative filmProcess (the active project's). Locked read-only here;
  // the mismatch/forcing rules are surfaced, never silently applied.
  filmProcess: FilmProcess;
  onChange: (next: ProcessingRecipe) => void;
}

const ICE_MODES: Array<ProcessingRecipe["digitalIceMode"]> = ["legacy", "hybrid"];

export default function ProcessingRecipeForm({
  processing,
  filmProcess,
  onChange,
}: ProcessingRecipeFormProps) {
  const isBwNegative = filmProcess === "bwNegative";
  // B&W: Digital ICE is forced off -- the infrared channel cannot make an
  // honest B&W ICE claim -- and the control is disabled with the note visible.
  const effectiveIceEnabled = isBwNegative ? false : processing.digitalIceEnabled;

  const update = (patch: Partial<ProcessingRecipe>): void => {
    onChange({
      ...processing,
      ...patch,
      digitalIceEnabled: isBwNegative ? false : patch.digitalIceEnabled ?? processing.digitalIceEnabled,
    });
  };

  return (
    <div className={styles.section} data-testid="processing-recipe-form">
      <div className={styles.sectionHeader}>
        <h3 className={styles.sectionTitle}>Processing</h3>
      </div>
      <div className={styles.sectionBody}>
        <div className={styles.fieldRow}>
          <span className={styles.fieldLabel}>Film process</span>
          <span
            className={styles.fieldValue}
            data-testid="processing-film-process-value"
            data-film-process={filmProcess}
          >
            {filmProcess}
          </span>
        </div>
        <div className={styles.checkboxRow}>
          <input
            id="processing-autofocus"
            className={styles.checkboxInput}
            type="checkbox"
            checked={processing.autofocusEachFrame}
            onChange={(event) => update({ autofocusEachFrame: event.target.checked })}
          />
          <label className={styles.fieldLabel} htmlFor="processing-autofocus">
            Autofocus each frame
          </label>
        </div>
        <div className={styles.checkboxRow}>
          <input
            id="processing-autoexposure"
            className={styles.checkboxInput}
            type="checkbox"
            checked={processing.autoExposureEachFrame}
            onChange={(event) => update({ autoExposureEachFrame: event.target.checked })}
          />
          <label className={styles.fieldLabel} htmlFor="processing-autoexposure">
            Auto-exposure each frame
          </label>
        </div>
        <div className={styles.checkboxRow}>
          <input
            id="processing-ice-enabled"
            className={styles.checkboxInput}
            type="checkbox"
            disabled={isBwNegative}
            checked={effectiveIceEnabled}
            onChange={(event) => update({ digitalIceEnabled: event.target.checked })}
          />
          <label className={styles.fieldLabel} htmlFor="processing-ice-enabled">
            Digital ICE enabled
          </label>
        </div>
        {effectiveIceEnabled && (
          <div className={styles.fieldRow}>
            <label className={styles.fieldLabel} htmlFor="processing-ice-mode">
              Digital ICE mode
            </label>
            <select
              id="processing-ice-mode"
              className={styles.selectInput}
              value={processing.digitalIceMode}
              onChange={(event) =>
                update({ digitalIceMode: event.target.value as ProcessingRecipe["digitalIceMode"] })
              }
            >
              {ICE_MODES.map((mode) => (
                <option key={mode} value={mode}>
                  {mode}
                </option>
              ))}
            </select>
          </div>
        )}
        {isBwNegative && (
          <>
            <p className={styles.disabledNote} data-testid="processing-ice-bw-note">
              Digital ICE is not available for B&W negatives: the infrared channel cannot make an
              honest B&W ICE claim. Rgb-only capture is used instead.
            </p>
            <div className={styles.checkboxRow}>
              <input
                id="processing-dust-removal-bw"
                className={styles.checkboxInput}
                type="checkbox"
                checked={processing.softwareDustRemovalBw === true}
                onChange={(event) => update({ softwareDustRemovalBw: event.target.checked })}
              />
              <label className={styles.fieldLabel} htmlFor="processing-dust-removal-bw">
                Software dust removal (B&W)
              </label>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

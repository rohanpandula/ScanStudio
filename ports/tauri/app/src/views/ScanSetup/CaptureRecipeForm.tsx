import type { FilmProcess, ResolvedCaptureRecipe } from "../../session/store/session";
import styles from "./ScanSetup.module.css";

export interface CaptureRecipeFormProps {
  capture: ResolvedCaptureRecipe;
  filmProcess?: FilmProcess;
  // Device-aware multisamplePasses options (session/store/session.ts's
  // multisampleOptionsForDevice, computed by the caller from the connected
  // DeviceInfo). Plain numbers, not the narrower ResolvedCaptureRecipe
  // union: a real device's wire-reported set is open-ended data, not a
  // client-side literal type. Not defaulted here: a real LS-5000 only
  // accepts [4], and a component-local [1,2,4,8,16] fallback would
  // silently re-introduce the defect this prop exists to fix (offering
  // multisample counts the connected device's own scan.start gate
  // rejects). Every render caller must pass the list it actually wants
  // offered.
  multisampleOptions: readonly number[];
  onChange: (next: ResolvedCaptureRecipe) => void;
}

export default function CaptureRecipeForm({
  capture,
  filmProcess,
  multisampleOptions,
  onChange,
}: CaptureRecipeFormProps) {
  const isBwNegative = filmProcess === "bwNegative";
  // B&W effective channels are forced to rgb (PROTOCOL.md); the control is
  // disabled and the forced value is always committed -- never silently
  // substituted without the visible note.
  const effectiveChannels: ResolvedCaptureRecipe["channels"] = isBwNegative
    ? "rgb"
    : capture.channels;

  const update = (patch: Partial<ResolvedCaptureRecipe>): void => {
    onChange({
      ...capture,
      ...patch,
      channels: isBwNegative ? "rgb" : (patch.channels ?? capture.channels),
    });
  };

  return (
    <div className={styles.section} data-testid="capture-recipe-form">
      <div className={styles.sectionHeader}>
        <h3 className={styles.sectionTitle}>Capture</h3>
      </div>
      <div className={styles.sectionBody}>
        <div className={styles.fieldRow}>
          <label className={styles.fieldLabel} htmlFor="capture-res-dpi">
            Resolution (Dpi)
          </label>
          <input
            id="capture-res-dpi"
            className={`${styles.numberInput} ${styles.fixedWidth}`}
            type="number"
            min={1}
            data-testid="capture-res-dpi"
            value={capture.resolutionDpi}
            onChange={(event) => update({ resolutionDpi: Number(event.target.value) })}
          />
        </div>
        <div className={styles.fieldRow}>
          <span className={styles.fieldLabel}>Bit depth</span>
          <div className={styles.radioGroup} role="radiogroup" aria-label="Bit depth">
            {[8, 16].map((depth) => (
              <div className={styles.radioRow} key={depth}>
                <input
                  id={`capture-bit-depth-${depth}`}
                  className={styles.checkboxInput}
                  type="radio"
                  name="capture-bit-depth"
                  value={depth}
                  checked={capture.bitDepth === depth}
                  onChange={() => update({ bitDepth: depth as 8 | 16 })}
                />
                <label className={styles.radioLabel} htmlFor={`capture-bit-depth-${depth}`}>
                  {depth} bits
                </label>
              </div>
            ))}
          </div>
        </div>
        <div className={styles.fieldRow}>
          <label className={styles.fieldLabel} htmlFor="capture-multisample">
            Multisample passes
          </label>
          <select
            id="capture-multisample"
            className={styles.selectInput}
            data-testid="capture-multisample"
            value={capture.multisamplePasses}
            onChange={(event) =>
              update({ multisamplePasses: Number(event.target.value) as ResolvedCaptureRecipe["multisamplePasses"] })
            }
          >
            {multisampleOptions.map((passes) => (
              <option key={passes} value={passes}>
                {passes}
              </option>
            ))}
          </select>
        </div>
        <div className={styles.fieldRow}>
          <span className={styles.fieldLabel}>Channels</span>
          <div className={styles.radioGroup} role="radiogroup" aria-label="Channels">
            <div className={styles.radioRow}>
              <input
                id="capture-channels-rgb"
                className={styles.checkboxInput}
                type="radio"
                name="capture-channels"
                value="rgb"
                disabled={isBwNegative}
                checked={effectiveChannels === "rgb"}
                onChange={() => update({ channels: "rgb" })}
              />
              <label className={styles.radioLabel} htmlFor="capture-channels-rgb">
                Rgb
              </label>
            </div>
            <div className={styles.radioRow}>
              <input
                id="capture-channels-rgbi"
                className={styles.checkboxInput}
                type="radio"
                name="capture-channels"
                value="rgbi"
                disabled={isBwNegative}
                checked={effectiveChannels === "rgbi"}
                onChange={() => update({ channels: "rgbi" })}
              />
              <label className={styles.radioLabel} htmlFor="capture-channels-rgbi">
                Rgb + infrared (rgbi)
              </label>
            </div>
          </div>
        </div>
        {isBwNegative && (
          <p className={styles.disabledNote} data-testid="capture-bw-channels-note">
            For B&W negatives, capture channels are forced to rgb because the infrared channel
            cannot make an honest B&W ICE claim.
          </p>
        )}
      </div>
    </div>
  );
}

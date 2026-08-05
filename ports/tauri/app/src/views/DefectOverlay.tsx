import type { AnalyzeFrameDefectsResult } from "../session/wire/types";
import styles from "./DefectOverlay.module.css";

export interface DefectOverlayProps {
  result: AnalyzeFrameDefectsResult;
}

/**
 * Defect overlay (UI-12). Renders one marker per DefectInstance over a
 * normalized 0-1 frame space (SVG viewBox 0 0 1 1): dust = circle, scratch =
 * line. Color is driven EXCLUSIVELY by the engine-resolved classification
 * field (red = willCorrect, amber = uncertain) -- never a client-side
 * threshold recomputation. The `simulated` badge is always visible when the
 * engine reports synthetic data, so synthetic analysis can never masquerade
 * as a real analysis of the user's film (DEF-02). Empty-defects copy is
 * disambiguated: "Digital ICE is off" (ICE disabled) vs. "no defects
 * detected" (ICE ran clean) are distinct messages (digitalIceEnabled echo).
 */
export default function DefectOverlay({ result }: DefectOverlayProps) {
  const { defects, simulated, digitalIceEnabled } = result;
  const isEmpty = defects.length === 0;

  return (
    <div className={styles.overlay} data-testid="defect-overlay">
      <div className={styles.header}>
        {simulated && (
          <span className={styles.simulatedBadge} data-testid="defect-simulated-badge">
            Simulated
          </span>
        )}
        {simulated === false && (
          <span className={styles.realBadge} data-testid="defect-real-badge">
            Real analysis
          </span>
        )}
      </div>

      {isEmpty ? (
        digitalIceEnabled ? (
          <p className={styles.cleanNotice} data-testid="defect-clean-notice">
            No defects detected (Digital ICE ran).
          </p>
        ) : (
          <p className={styles.iceOffNotice} data-testid="defect-ice-off-notice">
            Digital ICE is off — no defect analysis performed.
          </p>
        )
      ) : (
        <svg
          className={styles.canvas}
          viewBox="0 0 1 1"
          preserveAspectRatio="none"
          data-testid="defect-canvas"
        >
          {defects.map((defect) => {
            if (defect.kind === "scratch") {
              const endX = defect.endX ?? defect.centerX;
              const endY = defect.endY ?? defect.centerY;
              return (
                <line
                  key={defect.id}
                  x1={defect.centerX}
                  y1={defect.centerY}
                  x2={endX}
                  y2={endY}
                  stroke={defect.classification === "willCorrect" ? "#dc2626" : "#d97706"}
                  strokeWidth={0.006}
                  className={styles.marker}
                  data-testid={`defect-marker-${defect.id}`}
                  data-kind="scratch"
                  data-classification={defect.classification}
                />
              );
            }
            return (
              <circle
                key={defect.id}
                cx={defect.centerX}
                cy={defect.centerY}
                r={defect.radius}
                fill="none"
                stroke={defect.classification === "willCorrect" ? "#dc2626" : "#d97706"}
                strokeWidth={0.006}
                className={styles.marker}
                data-testid={`defect-marker-${defect.id}`}
                data-kind="dust"
                data-classification={defect.classification}
              />
            );
          })}
        </svg>
      )}
    </div>
  );
}

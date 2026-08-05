import { useEffect, useState } from "react";
import { useSyncExternalStore } from "react";
import { sessionStore, type SessionState } from "../../session";
import type {
  MetadataSet,
  PreviewMetadataCommandResult,
  ExifToolDetection,
  AnalyzeFrameDefectsResult,
} from "../../session/wire/types";
import ApprovalPanel from "./ApprovalPanel";
import SpacingOffsetControl from "./SpacingOffsetControl";
import DefectOverlay from "../DefectOverlay";
import FrameMetadataOverride from "../FrameMetadataOverride";
import ZoomPanViewer from "./ZoomPanViewer";
import styles from "./FrameDetail.module.css";

// useSyncExternalStore requires a referentially stable snapshot between
// store notifications, but SessionStore.getState() deep-clones on every call.
// Cache one snapshot per store generation here (same stable-snapshot bridge
// as DeviceBar/ContactSheet).
let cachedStore: unknown = null;
let cachedSnapshot: Readonly<SessionState> | null = null;

function stableSubscribe(listener: () => void): () => void {
  const unsubscribe = sessionStore.subscribe(() => {
    cachedSnapshot = null;
    listener();
  });
  return unsubscribe;
}

function stableGetSnapshot(): Readonly<SessionState> {
  if (cachedStore !== sessionStore) {
    cachedStore = sessionStore;
    cachedSnapshot = null;
  }
  if (cachedSnapshot === null) {
    cachedSnapshot = sessionStore.getState();
  }
  return cachedSnapshot;
}

// The frame's effective metadata: its own override if set, else the roll-wide
// default (never a field-level merge -- a MetadataSet is whole-object).
function effectiveMetadata(override: MetadataSet | null, roll: MetadataSet | null): MetadataSet {
  if (override !== null) return override;
  if (roll !== null) return roll;
  return { keywords: [] };
}

const DEFAULT_CAPTURE = {
  resolutionDpi: 4000,
  bitDepth: 16 as const,
  multisamplePasses: 1 as const,
  channels: "rgbi" as const,
};

const DEFAULT_PROCESSING = {
  filmProcess: "positive" as const,
  autofocusEachFrame: false,
  autoExposureEachFrame: false,
  digitalIceEnabled: true,
  digitalIceMode: "hybrid" as const,
  softwareDustRemovalBw: false,
};

export default function FrameDetailView({
  frameIndex,
  onClose,
}: {
  frameIndex: number;
  onClose?: () => void;
}) {
  const state = useSyncExternalStore(stableSubscribe, stableGetSnapshot);
  const thumbnail = state.thumbnails[frameIndex];
  const project = state.project;
  const frame = project?.frames.find((f) => f.index === frameIndex) ?? null;
  const roll = project?.rollMetadata ?? null;
  const override = frame?.metadataOverride ?? null;
  const derivativeTransform = sessionStore.frameDerivativeTransform(frameIndex);
  const transformsEditable = sessionStore.frameTransformsAreEditable();

  // ExifTool detection + preview + defect analysis are effect-driven
  // (fetch-on-open), so the panel and overlay stay honest: detection shows
  // the capability chip, preview shows the exact command, and the overlay
  // renders whatever the engine reports (including simulated).
  const [exifToolDetection, setExifToolDetection] = useState<ExifToolDetection | null>(null);
  const [metadataPreview, setMetadataPreview] = useState<PreviewMetadataCommandResult | null>(
    null,
  );
  const [defectResult, setDefectResult] = useState<AnalyzeFrameDefectsResult | null>(null);

  useEffect(() => {
    setExifToolDetection(null);
    setMetadataPreview(null);
    setDefectResult(null);
    void sessionStore
      .detectExifTool()
      .then((result) => {
        if (result !== undefined && result !== null && typeof result.available === "boolean") {
          setExifToolDetection(result);
        }
      })
      .catch(() => setExifToolDetection(null));
    void sessionStore
      .previewMetadataCommand(frameIndex)
      .then((result) => {
        if (result !== undefined && result !== null && Array.isArray(result.arguments)) {
          setMetadataPreview(result);
        }
      })
      .catch(() => setMetadataPreview(null));
    void sessionStore
      .analyzeFrameDefects(frameIndex, DEFAULT_CAPTURE, DEFAULT_PROCESSING)
      .then((result) => {
        // Guard: the scripted transports in existing tests return undefined
        // for unscripted methods; only a well-formed result may drive the
        // overlay (and its honest simulated badge).
        if (result !== undefined && result !== null && Array.isArray(result.defects)) {
          setDefectResult(result);
        }
      })
      .catch(() => setDefectResult(null));
  }, [frameIndex]);

  if (thumbnail === undefined) {
    return (
      <div className={styles.frameDetail} data-testid="frame-detail-loading">
        <p className={styles.loadingText}>Loading preview for frame {frameIndex}…</p>
      </div>
    );
  }

  return (
    <div className={styles.frameDetail} data-testid="frame-detail-view">
      <header className={styles.header}>
        <h2 className={styles.heading}>Frame {frameIndex}</h2>
        {onClose !== undefined && (
          <button
            type="button"
            className={styles.controlButton}
            data-testid="frame-detail-close"
            onClick={onClose}
          >
            Close
          </button>
        )}
      </header>
      <div className={styles.previewStack} data-testid="preview-stack">
        <ZoomPanViewer
          imagePath={thumbnail.imagePath}
          alt={`Frame ${frameIndex} preview`}
          derivativeTransform={derivativeTransform}
          overlay={defectResult !== null ? <DefectOverlay result={defectResult} /> : undefined}
        />
      </div>
      <div className={styles.orientationControls} data-testid="detail-transform-controls">
        <button
          type="button"
          className={styles.controlButton}
          disabled={!transformsEditable}
          onClick={() => sessionStore.rotateFrames([frameIndex], -90)}
        >
          Rotate left
        </button>
        <button
          type="button"
          className={styles.controlButton}
          disabled={!transformsEditable}
          onClick={() => sessionStore.rotateFrames([frameIndex], 90)}
        >
          Rotate right
        </button>
        <button
          type="button"
          className={styles.controlButton}
          disabled={!transformsEditable}
          onClick={() => sessionStore.toggleHorizontalMirror([frameIndex])}
        >
          Flip left/right
        </button>
        <button
          type="button"
          className={styles.controlButton}
          disabled={!transformsEditable}
          onClick={() => sessionStore.toggleVerticalMirror([frameIndex])}
        >
          Flip top/bottom
        </button>
        <button
          type="button"
          className={styles.controlButton}
          disabled={!transformsEditable}
          onClick={() => sessionStore.resetFrameTransforms([frameIndex])}
        >
          Reset
        </button>
        <span className={styles.rangeLabel} data-testid="detail-transform-summary">
          {derivativeTransform.rotationDegrees}°
          {derivativeTransform.horizontalMirror ? " · left/right flip" : ""}
          {derivativeTransform.verticalMirror ? " · top/bottom flip" : ""}
        </span>
      </div>
      <FrameMetadataOverride
        frameIndex={frameIndex}
        effectiveMetadata={effectiveMetadata(override, roll)}
        override={override}
        onSetOverride={(next: MetadataSet | null) =>
          void sessionStore.setFrameMetadataOverride(frameIndex, next)
        }
        exifToolDetection={exifToolDetection}
        metadataPreview={metadataPreview}
        onPreviewCommand={() =>
          void sessionStore
            .previewMetadataCommand(frameIndex)
            .then((result) => {
              if (result !== undefined && result !== null && Array.isArray(result.arguments)) {
                setMetadataPreview(result);
              }
            })
            .catch(() => setMetadataPreview(null))
        }
        onApply={() => sessionStore.applyMetadata(frameIndex)}
      />
      <SpacingOffsetControl frameIndex={frameIndex} />
      <ApprovalPanel frameIndex={frameIndex} />
    </div>
  );
}

import { useEffect, useRef, useState, type ReactNode } from "react";
import { previewImageSrc } from "../../session/webApis";
import type { DerivativeTransform } from "../../session/wire/types";
import styles from "./FrameDetail.module.css";

// CSS-transform zoom/pan viewer (06-01 Task 1). Wheel zooms (clamped [1, 8]),
// mouse drag pans only when zoomed in past scale 1, and the `-`/`+`/`=`/`0`
// keys step/reset zoom. The keydown listener is attached to the component's
// own container ref, never window/document, so these keys never hijack other
// app or webview shortcuts (T-06-01).
const MIN_SCALE = 1;
const MAX_SCALE = 8;
const ZOOM_STEP = 0.1;

function clampScale(scale: number): number {
  return Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale));
}

function stepScale(scale: number, delta: number): number {
  // Round to clean two-decimal increments so tests and CSS transforms agree.
  const next = Math.round((scale + delta) * 100) / 100;
  return clampScale(next);
}

export default function ZoomPanViewer({
  imagePath,
  alt,
  derivativeTransform = {
    rotationDegrees: 0,
    horizontalMirror: false,
    verticalMirror: false,
  },
  overlay,
}: {
  imagePath?: string | undefined;
  alt?: string | undefined;
  derivativeTransform?: DerivativeTransform;
  overlay?: ReactNode;
}) {
  const [scale, setScale] = useState(MIN_SCALE);
  const [translate, setTranslate] = useState({ x: 0, y: 0 });
  const [drag, setDrag] = useState<{ lastX: number; lastY: number } | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const scaleRef = useRef(MIN_SCALE);
  useEffect(() => {
    scaleRef.current = scale;
  }, [scale]);

  useEffect(() => {
    const node = containerRef.current;
    if (node === null) return;
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === "+" || event.key === "=") {
        event.preventDefault();
        setScale((current) => stepScale(current, ZOOM_STEP));
      } else if (event.key === "-") {
        event.preventDefault();
        setScale((current) => stepScale(current, -ZOOM_STEP));
      } else if (event.key === "0") {
        event.preventDefault();
        setScale(MIN_SCALE);
        setTranslate({ x: 0, y: 0 });
      }
    };
    node.addEventListener("keydown", onKeyDown);
    return () => {
      node.removeEventListener("keydown", onKeyDown);
    };
  }, []);

  const handleWheel = (event: React.WheelEvent<HTMLDivElement>): void => {
    event.preventDefault();
    const direction = event.deltaY < 0 ? ZOOM_STEP : -ZOOM_STEP;
    setScale((current) => stepScale(current, direction));
  };

  const startDrag = (event: React.MouseEvent<HTMLDivElement>): void => {
    if (event.button !== 0) return;
    event.preventDefault();
    setDrag({ lastX: event.clientX, lastY: event.clientY });
  };

  const moveDrag = (event: React.MouseEvent<HTMLDivElement>): void => {
    if (drag === null || scaleRef.current <= 1) return;
    const dx = event.clientX - drag.lastX;
    const dy = event.clientY - drag.lastY;
    setTranslate((current) => ({ x: current.x + dx, y: current.y + dy }));
    setDrag({ lastX: event.clientX, lastY: event.clientY });
  };

  const endDrag = (): void => setDrag(null);
  const swapsAxes =
    derivativeTransform.rotationDegrees === 90 ||
    derivativeTransform.rotationDegrees === 270;

  return (
    <div
      ref={containerRef}
      className={styles.viewport}
      tabIndex={0}
      data-testid="zoom-pan-viewer"
      data-axis-swapped={swapsAxes}
      style={{ aspectRatio: swapsAxes ? "2 / 3" : "3 / 2" }}
      onWheel={handleWheel}
      onMouseDown={startDrag}
      onMouseMove={moveDrag}
      onMouseUp={endDrag}
      onMouseLeave={endDrag}
    >
      {imagePath !== undefined ? (
        <div
          className={styles.panLayer}
          data-testid="pan-layer"
          style={{
            transform: `translate(${translate.x}px, ${translate.y}px) scale(${scale})`,
          }}
        >
          <div
            className={styles.derivativeLayer}
            data-testid="derivative-layer"
            data-axis-swapped={swapsAxes}
            data-rotation={derivativeTransform.rotationDegrees}
            data-horizontal-mirror={derivativeTransform.horizontalMirror}
            data-vertical-mirror={derivativeTransform.verticalMirror}
            style={{
              width: swapsAxes ? "150%" : "100%",
              height: swapsAxes ? "66.6667%" : "100%",
              // CSS evaluates transform functions right-to-left: source-axis
              // mirrors run first, then the clockwise quarter-turn, and the
              // centered source plane is placed into the display viewport.
              transform:
                `translate(-50%, -50%) rotate(${derivativeTransform.rotationDegrees}deg) ` +
                `scaleX(${derivativeTransform.horizontalMirror ? -1 : 1}) ` +
                `scaleY(${derivativeTransform.verticalMirror ? -1 : 1})`,
            }}
          >
            <img
              className={styles.previewImage}
              src={previewImageSrc(imagePath)}
              alt={alt ?? "Frame preview"}
              draggable={false}
              data-testid="zoom-pan-image"
              data-scale={scale}
              data-translate-x={translate.x}
              data-translate-y={translate.y}
              data-rotation={derivativeTransform.rotationDegrees}
              data-horizontal-mirror={derivativeTransform.horizontalMirror}
              data-vertical-mirror={derivativeTransform.verticalMirror}
            />
            {overlay !== undefined && (
              <div className={styles.viewerOverlay} data-testid="viewer-overlay">
                {overlay}
              </div>
            )}
          </div>
        </div>
      ) : (
        <span className={styles.empty} data-testid="zoom-pan-empty">
          No preview image
        </span>
      )}
    </div>
  );
}

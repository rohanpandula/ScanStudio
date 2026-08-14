# SwiftUI ↔ Tauri parity ledger (07-03 Task 3)

Exhaustive mapping of the 14 SwiftUI source files under
`nikon-coolscan4-software-archaeology/app/ScanStudio/Sources/ScanStudio/` to
their Tauri equivalents in `app/src/`. One row per SwiftUI file; every row
carries a reasoned status and non-empty notes. This document is consumable by
Phase 10's human sign-off checklist — accuracy matters more than polish.

Mapping matches by responsibility (what the view does), not by name similarity.

| SwiftUI file | Tauri equivalent | status | notes |
|---|---|---|---|
| `ScanStudioApp.swift` | `src/App.tsx` | parity | App entry + window/root. Tauri 2 owns the window/shell lifecycle in Rust (`src-tauri`); `src/App.tsx` is the React root that composes the workspace and owns the contact/frame-detail/capture navigation. Parity via Tauri's own window management plus the App-level reachability test (`src/__tests__/App.test.tsx`). |
| `ContentView.swift` | `src/shell/AppShell.tsx` | parity | Three-pane shell (sidebar/workspace/inspector) with `shell-sidebar`/`shell-workspace`/`shell-inspector` regions — matches ContentView's primary split layout. |
| `DeviceBarView.swift` | `src/views/DeviceBar.tsx` | parity | Honest device list with literal `kind` labeling, connect/disconnect, live ScannerStatus; 07-03 added HardwareStatusChips (gated on real backend) + HardwareErrorPanel below the status block. |
| `SessionSidebarView.swift` | `src/views/ProjectPanel.tsx` (+ `src/views/DeviceBar.tsx`) | parity | Project create/open/recent list + active-project banner, combined with the device bar in the sidebar column of `AppShell`. (SwiftUI splits device/projects differently; the sidebar region covers both responsibilities.) |
| `ProjectLauncherView.swift` | `src/views/ProjectPanel.tsx` | parity | New-project form (carrier/frameCount/client validation), native directory picker, schemaVersion-4 manifest writing — all in ProjectPanel with exact PROTOCOL.md ranges. |
| `ThumbnailGridView.swift` | `src/views/ContactSheet.tsx` | parity | Preview contact sheet: both one-of tile modes (brightness/tint shaded placeholder vs `scanstudio-preview://` image), progressive arrival, multi-select (click/shift/select-all/clear) via `sessionStore` selection methods. Intentional note: SwiftUI's "Preview as positive" display toggle is not ported (out of scope per 07-CONTEXT decision in Phase 6 context). |
| `FrameDetailWorkspaceView.swift` | `src/views/FrameDetail/FrameDetailView.tsx` | parity | Frame inspection: zoom/pan viewer, spacing-offset control, approval panel; 07-03 added FrameMetadataOverride (per-frame metadata + ExifTool preview/apply) and the DefectOverlay layered over the preview. |
| `FrameAlignmentControl.swift` | `src/views/FrameDetail/SpacingOffsetControl.tsx` | parity | Range-bounded spacing-offset stepper/drag handle writing through the store's `setSpacingOffset` (server-returned tile adopted; approval invalidated on change). |
| `ScanPanelView.swift` | `src/views/ScanSetup/ScanSetupView.tsx` + `src/views/ScanRun/ScanRunView.tsx` | parity | Scan configuration (recipe forms, per-frame overrides, Start with verbatim field errors) + live job panel (per-frame states, cooperative stop, ETA) + PendingFramesPanel resume — composed by `src/views/Capture/CaptureWorkflowView.tsx`. |
| `HardwareMotionReadinessView.swift` | `src/views/HardwareStatusChips.tsx` + `src/views/HardwareErrorPanel.tsx` | parity | Real-backend tri-state `motionArmed`/`filmPresent` chips (null rendered as "Unknown", never absence) and typed hardware-error panel (FEEDER_PARKED power-cycle guidance, HW_MOTION_NOT_ARMED operator-owned latch) — mounted only for a real backend via DeviceBar's `kind === "real"` gate. SAFE-02: the app never offers an in-app arm action. |
| `RollLoadingWorkspaceView.swift` | `src/views/ContactSheet.tsx` (load-media controls) + `src/views/DeviceBar.tsx` (status) | parity | `sim.loadMedia` carrier buttons (roll36/strip6/mounted) render when no media loaded; media state surfaces in the device bar status. Real-hardware load/eject mechanics remain engine/runbook-side (Phase 10), matching the simulator-first contract. |
| `BatchInspectorView.swift` | `src/views/MetadataPanel.tsx` + `src/views/PartialDateEditor.tsx` + `src/views/FrameMetadataOverride.tsx` | parity | Roll-wide + per-frame metadata editing with correct PartialDate semantics (exact/monthOnly/yearOnly/unknown, never fabricated precision) and the ExifTool detect/preview/apply flow (exact command rendered before apply). Whole-object swap semantics on overrides. |
| `DefectMapView.swift` | `src/views/DefectOverlay.tsx` | parity | SVG defect markers (dust circle / scratch line) colored by the engine-resolved classification (red=willCorrect, amber=uncertain), always-visible simulated/real badge, and distinct ICE-off vs clean-empty notices. |
| `ScanStudioTheme.swift` | CSS modules throughout `src/views/*.module.css` + `src/shell/*.module.css` | parity | Styling only: SwiftUI's Theme struct maps to the project's CSS-module approach (DeviceBar/ContactSheet/ScanSetup/ScanRun/HardwareStatus/DefectOverlay modules). No dedicated single theme file; tokens are per-module CSS custom properties, consistent with the chosen styling approach. |

## Overall parity claim

Every one of the 14 SwiftUI views has a real, reachable Tauri equivalent
(single row marked "intentional gap": none). The two documented differences —
SwiftUI's "Preview as positive" toggle (not ported) and the theme-file
organization (CSS modules instead of a `Theme` struct) — are named intentional
choices, not omissions. Reachability of the newly-wired Phase 7 components is
guard-railed by `src/__tests__/App.test.tsx` (shell navigation) and the
fixture-driven component tests.

## Known parity gaps opened after this ledger was written

This ledger was written at Phase 07-03 and maps the 14 SwiftUI files that
existed then. Two later SwiftUI features have no Tauri equivalent. They are
recorded here rather than silently carried as "parity".

| SwiftUI feature | Added | Tauri status | notes |
|---|---|---|---|
| Manual frame placement (`ManualFramePlacementView.swift`, `ManualFramePlacementSheet`, `ManualFramePlacementValidation.swift`) | 2026-08-07 (feeding UX ladder, Rung 4) | **GAP — not ported** | The Tauri app implements neither `roll.previewStrip` nor `roll.manualFrames`; there is no strip editor and no boundary-drawing UI. A Tauri operator whose roll refuses with `REFEED_REQUIRED` can only refeed and retry. Porting this is a whole subsystem (raster strip viewer, draggable boundary model, row validation), not an affordance, and is deliberately out of scope for the feed-detector round. |
| Attended scan binding — "Approve every frame and scan" (`ErrorPresentation.canApproveEveryFrameAndScan`, `SessionModel.approveEveryFrameAndScan`, workspace error-card button) | 2026-08-13 (feed-detector round; issues #24/#16/#42) | **partial — wire and store parity, no error-card button** | `SessionStore.approveFrame(frameIndex, { attended })` and `SessionStore.approveEveryFrameAttended(frames)` exist and are tested, so the capability is reachable from the Tauri store. What is not ported is the SwiftUI *presentation* layer that turns a confidence refusal into a one-click recovery: the Tauri app has no `ErrorPresentationPolicy` equivalent classifying refusal text into copy plus affordances (`src/session/store/session.ts` handles only the `FILM_FEED_INTERRUPTED` legacy-compat classification). Adding the button means porting that policy layer first. |

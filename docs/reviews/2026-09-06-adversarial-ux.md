# Adversarial desktop UX review — 2026-09-06

Method: independent native source assessment (Feynman), Tauri assessment and detector (Boyle), and parent-led native interaction/state-machine testing. The baseline is ScanStudio v0.7.0-beta.13. This report describes subsequent fixes on `codex/adversarial-ux-review`; those fixes are not part of the published beta.13 assets.

## Findings and disposition

| Priority | Finding and triggering scenario | Correction |
| --- | --- | --- |
| P1 | Open or create a project while preview acquisition is active: the project changes, and opening clears the UI's active preview state before the operation finishes. | Shared model/UI project-change guard preserves active preview ownership. The reverse overlap, starting preview while opening a project, is rejected too. |
| P1 | On a 1,024-point Mac desktop, fixed sidebar + workspace + inspector widths put most Batch Settings offscreen. | Compact layouts move the sidebar into a labeled popover, retain the inspector, and allow the scan footer to scroll. Project dialogs are presented from the window, keeping them onscreen. |
| P1 | Native frame detail offers Final and Before Repair, but both load the same scanner thumbnail. | Remove the false comparison. Label the available image Scanner Preview and retain the separate defect overlay. |
| P1 | Tauri Capture selected has no return action; a new project can retain the previous local scan panel. | Add Back to film when the session is idle and reset capture state at project/job boundaries. |
| P1 | Tauri inspection without a thumbnail shows Loading preview forever and omits Close, though no preview was requested. | Keep Close in every state. Show loading only for an active preview; otherwise explain how to acquire one. |
| P1 | A failed Tauri Stop request rejects a discarded promise and gives the operator no feedback. | Show pending, acknowledged, and error states; prevent duplicate pending requests and retain retry access. |
| P1 | Navigate away, change the store, and return: module-level snapshot caches can display the previous session state because their listeners were absent. | Invalidate every affected snapshot cache on subscription so React's post-subscription check sees current state. |
| P2 | After a partial scan, Check remaining frames fetches and discards its result; a separate panel asks users to load data already requested by its parent. | One pending-frames panel owns loading, visible errors, refresh, and resume. Its state resets for a new job. |
| P2 | Tauri frame tiles expose visual selection only, leaving assistive technology unable to identify included frames. | Expose each tile's state through `aria-pressed`. |
| P2 | Mac New/Open Project before previewing repeats prerequisites and has no visible Cancel. Open Recent exposes internal process identifiers and UTC timestamps without loading/submission feedback. | Present one prerequisite explanation, a visible Cancel, readable film/date labels, loading/opening feedback, and a reload action. Prevent duplicate submissions. Escape already worked in the baseline, so this was not a complete modal trap. |
| P2 | Opening an unsaved native preview automatically requests project-only defect analysis and shows an error even though preview editing is allowed. | Run analysis and expose project-only editing only after saving; retain preview zoom, pan, and transforms before saving. |
| P2 | Native keyboard users can zoom but cannot pan to off-center image details. | Add focus-scoped arrow-key panning, named accessibility actions, and viewport bounds. |
| P2 | The native update heading uses fixed amber text over a pale amber background in Light appearance. Token arithmetic gives about 1.95:1 contrast over white. | Use semantic primary text, preserving amber for decoration. The baseline estimate was calculated, not sampled from native pixels. |
| P2 | Native Stop Scan suggests an immediate real-scanner abort, but the real backend always translates it to stopping after the current frame. | Label real-device behavior Stop after frame. Immediate Stop remains simulator-only. |

The native state-machine regression failed before the fix for both create and open, including proof that opening set `isAcquiringThumbnails` to false. Tauri characterization/regression checks reproduced navigation, missing-preview, stop, resume, and remount failures. Fixes preserve explicit physical-motion authorization and do not add a new rendering or repair pipeline.

## Native design assessment

The interface is specific to film scanning: the contact sheet, holder identity, frame overrides, and hardware readiness provide useful structure. Preserve the explicit simulator label, honest indeterminate hardware progress, preview-versus-output distinction, contextual error guidance, and existing adaptive contact-sheet header.

Baseline heuristic scores (0–4, before fixes):

| Heuristic | Score |
| --- | ---: |
| Visibility of system status | 3 |
| Match with the real world | 2 |
| User control and freedom | 2 |
| Consistency and standards | 3 |
| Error prevention | 3 |
| Recognition rather than recall | 2 |
| Flexibility and efficiency | 2 |
| Aesthetic and minimalist design | 2 |
| Error recovery | 3 |
| Help and documentation | 2 |
| Total | 24/40 |

This is a baseline qualitative assessment, not a measured post-fix score. Scan Settings remains dense; presets and grouped sections reduce that load. No additional redesign was justified by the bounded review.

## Detector and verification scope

The Tauri detector scanned the actual frontend source and reported zero errors and one warning: the setup checker's three-pixel status border. This is a literal style match without a demonstrated usability failure, so it was retained. Browser inspection reached the frontend shell; native Tauri APIs were unavailable in that browser. No browser overlay was claimed.

Native checks used the released DMG to establish baseline behavior and a locally built development app to verify corrections. The corrected compact layout, sidebar access, centered project dialog, visible Cancel, recent-project labels, project opening, and scan footer were inspected on the 1,024-point display.

Final automated and interaction results are recorded below after integration. Hardware motion was not performed. Existing hardware-validation issues #77, #23, #25, #27, and #28 remain dependent on physical scanner evidence. Displays narrower than 980 points remain outside the native app's supported minimum.

## Final results

- Swift: 78 XCTest tests and 506 Swift Testing tests passed. Final native executable builds successfully.
- Tauri: 473 frontend tests passed with six environment-gated tests skipped in the full run. All six were then enabled against the bundled simulator-only engine: all 17 tests across the three subprocess test files passed.
- Tauri typecheck and production build passed.
- Vendor synchronization and diff-integrity checks passed.
- Live Mac verification confirmed the compact layout, window-owned project sheet, readable recent list, visible cancellation, accessible scan footer, honest Scanner Preview label, unsaved preview without the automatic error, and actual arrow-key pan in both directions. Named accessibility pan actions also moved the image. The native move-command handler was used after live key delivery exposed that the initial key-press approach did not pan.
- The unsaved-project defect selector is disabled until a project exists. Per-frame project settings and metadata actions remain available after saving.

No claim is made that this finite review proves the absence of every bug. No physical scanner behavior or Light-appearance update announcement was exercised live in this pass; those fixes were checked against their backend contract and semantic appearance behavior respectively. Original uncommitted changes in the separate ScanStudio checkout were preserved.

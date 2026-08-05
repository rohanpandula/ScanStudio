# Real-backend fixture provenance ledger (07-02 Task 1)

These NDJSON files exercise the real-backend honesty affordances (07-CONTEXT
decision 3) with **zero hardware and zero bridge process present**. Every line
derives from the frozen contracts:
`vendor/protocol/PROTOCOL.md` and `vendor/protocol/BRIDGE.md` (read-only).

Per the doc-derived-only rule, any value the docs give as a **concrete example**
is copied **verbatim**; any value the docs describe only by **shape/type** may
be invented but must stay shape-valid and is **ledgered below** as invented.

## Invented-but-shape-valid values (non-verbatim)

| File | Line | Field(s) | Shape constrained by |
|------|------|----------|----------------------|
| `03-real-thumbnail-boundary-warnings.ndjson` | 2 | `warnings: ["low confidence boundary detection"]` | `Thumbnail.warnings: string[]` (PROTOCOL.md); content invented for the shape |
| `03-real-thumbnail-boundary-warnings.ndjson` | both thumbnails | `imagePath: "/mnt/c/film/frame000*.tif"`, `spacingOffset: 3 / -2` | `imagePath: string` (imagePath mode), `spacingOffset: u32` valid ranges (PROTOCOL.md); concrete values invented |
| `03-real-thumbnail-boundary-warnings.ndjson` | all | `operationId: "op-fixture-boundary"` | any string; the same id must be echoed by the trailing `thumbnailsComplete` |
| `04-stream-stalled-preview-failure.ndjson` | 1 | `message: "bridge event stream stalled…"` | `code: "BRIDGE_STREAM_STALLED"` and the field shape verbatim from PROTOCOL.md (the runtime sample may carry a richer message); the concrete message text is invented-but-shape-valid |
| `04-stream-stalled-preview-failure.ndjson` | both | `operationId: "op-fixture-stall"` | any string; echoed between the failed + zero-count complete pair |
| `02-typed-hardware-errors.ndjson` | 1, 3 | request `params` (frames/recipe/filmProcess) | standard `scan.start` / `scanner.acquireThumbnails` params shapes; concrete values invented |
| `02-typed-hardware-errors.ndjson` | 2, 4 | request `id` (205/206) | any integer |

## Verbatim doc-derived values (copied exactly — do not edit)

- `02-typed-hardware-errors.ndjson` line 2: the whole `error` object —
  `code: "FEEDER_PARKED"`, `message: "transport parked at end-stop after slot 14; power cycle required before further motion"`, `recoverable: false` (BRIDGE.md `hardware.anomaly` example).
- `02-typed-hardware-errors.ndjson` line 4: the whole `error` object —
  `code: "HW_MOTION_NOT_ARMED"`, `message: "motion refused: SCANSTUDIO_HW_MOTION unset or hw-motion-armed latch missing/empty"`, `recoverable: false` (BRIDGE.md `roll.preview` refusal example).
- `03-real-thumbnail-boundary-warnings.ndjson` line 1: `boundaryRows: [12, 884]`
  (BRIDGE.md's own example value).
- `04-stream-stalled-preview-failure.ndjson`: `code: "BRIDGE_STREAM_STALLED"`
  and the event pairing rule (zero-count `thumbnailsComplete` preceded by
  `thumbnailsFailed` is a failure) verbatim from PROTOCOL.md.
- Field-shape rule for `ScannerStatus.motionArmed`/`filmPresent`: "`null` is
  never absence; the simulator omits the field rather than fabricating a
  hardware-ready state" (PROTOCOL.md) — `01-hardware-status-tristate.ndjson`
  exercises true/false/null (null = real backend, no trustworthy verdict yet).

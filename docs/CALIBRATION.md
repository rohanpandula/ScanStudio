# Calibration runbook

This is an attended, evidence-producing procedure for the LS-5000 calibration
roll. It is a command sequence, not a completion claim. The simulator has
already exercised repeat, verify, and collect; a physical result remains
`UNVALIDATED` until the operator reviews the retained evidence.

Record these inputs before starting:

- the exact signed `scanstudio-cli` path and a private control socket;
- the discovered scanner ID (for example `ls5000-usb-0`), the film stock, the
  project directory, operator name, and a unique evidence destination;
- a placement JSON file and a slot map JSON file. The CLI never chooses a
  scanner, film identity, placement, or slot map;
- explicit settings and output JSON files for Pass A and Pass B, made from
  `settings get` and `outputs get` and reviewed by the operator;
- the candidate app, bridge, CoolscanPy, and driver versions. Record the
  published driver candidate as `0.7.9` when that is the build under review;
  record the actual app/bridge versions separately. Stamp each local candidate
  with a unique version before presenting its attended commands.

No command below ejects, reloads, retries, or claims that calibration is
complete. Stop at the first refusal. An operator checkpoint is required at
each physical reload and before beginning an authorized motion sequence.

## Fixed capture contract

Both passes are 4000 dpi, 16-bit, RGBI, single-sample (`multisample=1`), with
autofocus enabled per frame. Pass A has auto exposure off, Digital ICE off,
raw linear TIFF enabled, and the archive/positive/preview derivatives off.
Pass B has auto exposure per frame, legacy Digital ICE on, raw export off, and
archive, positive, and preview derivatives on. Use an explicit `--from-json`
recipe for each pass so destinations and formats are visible in the command
record. The raw TIFF must be 16-bit RGB with its grayscale IR sidecar and the
`scanstudio.infrared.linear.uint16.v1` marker. Do not treat an archive TIFF as
the raw export.

The reviewed JSON recipes must show these values before the first motion:

| Recipe | Capture | Processing | Retained outputs |
| --- | --- | --- | --- |
| A | `resolutionDpi: 4000`, `bitDepth: 16`, `multisamplePasses: 1`, `channels: "rgbi"` | `autofocusEachFrame: true`, `autoExposureEachFrame: false`, ICE disabled | `rawExport.enabled: true`, `fileFormat: "linearTiff"`, `tiffInfrared: "sidecar"`; archive, positive, and preview disabled |
| B | same capture values | `autofocusEachFrame: true`, `autoExposureEachFrame: true`, `digitalIceEnabled: true`, `digitalIceMode: "legacy"` | raw export disabled; archive enabled; positive enabled with `c41Render.target: "nikonlook"`; preview enabled |

Every enabled output needs an explicit destination. Keep the A and B recipe
files with the run evidence; do not rely on a remembered GUI setting.

The durable RGB exposure lock is solved once from frame 2 in Pass A. Its RGB
ticks are reused by the AE-off scans; IR remains metered. Exposure ticks are
driver values in 10 ns units, subject to the LS-5000 protocol range
50,000...400,000. The receipts and project lock are the authority. Simulator
or missing hardware telemetry is `Unknown`, never a fabricated exposure.

Create a fresh project with `roll save --no-scan` before solving exposure.
This writes the project without starting a preview or capture:

```sh
"$CLI" roll save --name calibration-portra400 --carrier roll36 --frame-count 36 \
  --film-process c41ColorNegative --no-scan --socket "$SOCKET" --attach
```

Use the returned `projectDirectory` as `PROJECT`, then apply the explicit
recipes below. Omit `--no-scan` only when an immediate scan is intended.

## CLI setup and attended checkpoints

All global options are shown explicitly. The wrapper in
`scripts/calibration_cli.sh` requires these values and has a dry-run mode; use
`--execute` only after the attended checkpoint has been completed.

```sh
CLI=/absolute/path/to/scanstudio-cli
SOCKET=/absolute/path/to/private/control.sock
DEVICE=the-exact-discovered-device-id
PROJECT=/absolute/path/to/owner-prepared-project
PLACEMENT=/absolute/path/to/placement.json
SLOT_MAP=/absolute/path/to/slot-map.json
SETTINGS_A=/absolute/path/to/settings-A.json
OUTPUTS_A=/absolute/path/to/outputs-A.json
SETTINGS_B=/absolute/path/to/settings-B.json
OUTPUTS_B=/absolute/path/to/outputs-B.json
STOCK='Portra400'
OPERATOR='operator-name'
```

Before the first motion, inspect discovery and status, then connect to the
exact ID. `status --refresh` is deliberately after `connect`; it is the live
readiness check.

```sh
"$CLI" rescan --socket "$SOCKET" --attach
"$CLI" connect --device "$DEVICE" --socket "$SOCKET" --attach
"$CLI" status --refresh --socket "$SOCKET" --attach
"$CLI" roll open "$PROJECT" --socket "$SOCKET" --attach
"$CLI" settings get --socket "$SOCKET" --attach
"$CLI" outputs get --socket "$SOCKET" --attach
```

The operator now confirms the film is loaded and authorizes the next motion.
Preview uses `--film-loaded`; exposure solve and capture use
`--confirm-motion`. The authorized run must cover each intended motion.

## Pass A: A1, A2, and ten frame-20 repeats

Use the reviewed A settings and outputs, then acquire a fresh preview, import
the explicit placement, and select exactly the intended frames. The placement
file is the hand-reviewed slot/frame map; it is not inferred from preview.

```sh
"$CLI" settings set --from-json "$SETTINGS_A" --socket "$SOCKET" --attach
"$CLI" outputs set --from-json "$OUTPUTS_A" --socket "$SOCKET" --attach
"$CLI" preview --film-loaded --socket "$SOCKET" --attach
"$CLI" frames place --from "$PLACEMENT" --socket "$SOCKET" --attach
"$CLI" frames select --all --socket "$SOCKET" --attach
"$CLI" roll solve-exposure --frame 2 --confirm-motion --socket "$SOCKET" --attach
```

Inspect the returned lock and status before authorizing A1. Scan the explicit
36-frame set (replace it only with the owner-approved physical frame set):

```sh
"$CLI" scan --frames 1-36 --pass A1 --confirm-motion --wait --socket "$SOCKET" --attach
```

After the terminal receipt, inspect its recipe, RGB authority, IR sidecar,
clipping fields, and saved file paths. A2 starts only after that checkpoint:

```sh
"$CLI" roll open "$PROJECT" --socket "$SOCKET" --attach
"$CLI" preview --film-loaded --socket "$SOCKET" --attach
"$CLI" frames place --replay --socket "$SOCKET" --attach
"$CLI" frames select --all --socket "$SOCKET" --attach
"$CLI" scan --frames 1-36 --pass A2 --confirm-motion --wait --socket "$SOCKET" --attach
```

For repeats, scan only frame 20. Each command below is one authorized job and
must reach a terminal result before the next command. The explicit tokens are
intentional: after the physical reload, numbering still starts at `Arep06`,
not at a CLI-generated `Arep01`.

```sh
# Current load: Arep01 ... Arep05
"$CLI" scan --frames 20 --pass Arep01 --confirm-motion --wait --socket "$SOCKET" --attach
"$CLI" scan --frames 20 --pass Arep02 --confirm-motion --wait --socket "$SOCKET" --attach
"$CLI" scan --frames 20 --pass Arep03 --confirm-motion --wait --socket "$SOCKET" --attach
"$CLI" scan --frames 20 --pass Arep04 --confirm-motion --wait --socket "$SOCKET" --attach
"$CLI" scan --frames 20 --pass Arep05 --confirm-motion --wait --socket "$SOCKET" --attach
```

At the attended checkpoint, stop and record the terminal receipts. Reload the
same film according to the hardware procedure, reconnect to the same explicit
device, refresh status, acquire a new preview, and replay the saved placement:

```sh
"$CLI" connect --device "$DEVICE" --socket "$SOCKET" --attach
"$CLI" status --refresh --socket "$SOCKET" --attach
"$CLI" roll open "$PROJECT" --socket "$SOCKET" --attach
"$CLI" preview --film-loaded --socket "$SOCKET" --attach
"$CLI" frames place --replay --socket "$SOCKET" --attach
"$CLI" frames select --all --socket "$SOCKET" --attach
```

The operator inspects the new preview and readiness state before authorizing
the second group:

```sh
# Reloaded load: Arep06 ... Arep10
"$CLI" scan --frames 20 --pass Arep06 --confirm-motion --wait --socket "$SOCKET" --attach
"$CLI" scan --frames 20 --pass Arep07 --confirm-motion --wait --socket "$SOCKET" --attach
"$CLI" scan --frames 20 --pass Arep08 --confirm-motion --wait --socket "$SOCKET" --attach
"$CLI" scan --frames 20 --pass Arep09 --confirm-motion --wait --socket "$SOCKET" --attach
"$CLI" scan --frames 20 --pass Arep10 --confirm-motion --wait --socket "$SOCKET" --attach
```

## Pass B and retained evidence

At the next attended checkpoint, apply the reviewed B recipes. Acquire a fresh
preview and replay placement against that preview before scanning. Pass B's
legacy ICE output is the positive derivative; its raw export is disabled.

```sh
"$CLI" settings set --from-json "$SETTINGS_B" --socket "$SOCKET" --attach
"$CLI" outputs set --from-json "$OUTPUTS_B" --socket "$SOCKET" --attach
"$CLI" preview --film-loaded --socket "$SOCKET" --attach
"$CLI" frames place --replay --socket "$SOCKET" --attach
"$CLI" frames select --all --socket "$SOCKET" --attach
"$CLI" scan --frames 1-36 --pass B --confirm-motion --wait --socket "$SOCKET" --attach
```

The receipt is the source of truth for per-frame meter results. The default
frame-failure policy is stop. For a reviewed set of known blank slots, add
`--on-frame-failure skip --allow-meter-refusal-slots RANGE` to that exact scan
command. Only a structured meter-controller refusal at a synchronized READY
boundary may skip a listed slot; transport, feed, recovery, and other errors
still stop. The simulator refuses this hardware-only policy.

A skipped slot retains a separate durable `skipRecords` entry with job, pass,
slot, and typed reason; it has no capture receipt. `roll collect` includes
those records even for an all-skipped pass. `roll verify` reports the skips
and leaves absent exposure/clipping measurements unknown. The driver callback
does not expose journal paths or hashes, so collection marks that evidence
unavailable. Do not resume by retrying a failed command.

## Verify, collect, and review gates

Verification is read-only and does not talk to the scanner. Run it once per
pass after all receipts are present. A and repeat passes require identical RGB
exposure and no clipping; B checks clipping only because auto exposure is
per-frame.

```sh
"$CLI" roll verify --pass A1 --exposure-identical --no-clipping --socket "$SOCKET" --attach
"$CLI" roll verify --pass A2 --exposure-identical --no-clipping --socket "$SOCKET" --attach
"$CLI" roll verify --pass Arep01 --exposure-identical --no-clipping --socket "$SOCKET" --attach
"$CLI" roll verify --pass Arep02 --exposure-identical --no-clipping --socket "$SOCKET" --attach
"$CLI" roll verify --pass Arep03 --exposure-identical --no-clipping --socket "$SOCKET" --attach
"$CLI" roll verify --pass Arep04 --exposure-identical --no-clipping --socket "$SOCKET" --attach
"$CLI" roll verify --pass Arep05 --exposure-identical --no-clipping --socket "$SOCKET" --attach
"$CLI" roll verify --pass Arep06 --exposure-identical --no-clipping --socket "$SOCKET" --attach
"$CLI" roll verify --pass Arep07 --exposure-identical --no-clipping --socket "$SOCKET" --attach
"$CLI" roll verify --pass Arep08 --exposure-identical --no-clipping --socket "$SOCKET" --attach
"$CLI" roll verify --pass Arep09 --exposure-identical --no-clipping --socket "$SOCKET" --attach
"$CLI" roll verify --pass Arep10 --exposure-identical --no-clipping --socket "$SOCKET" --attach
"$CLI" roll verify --pass B --no-clipping --socket "$SOCKET" --attach
```

Choose a fresh, non-existent destination for each collection. The slot map
must map unique positive scanner slots to unique positive physical frames.
Collection copies and hashes retained evidence, refuses missing/tampered
inputs and existing destinations, and never rewrites the project originals.

```sh
"$CLI" roll collect --to /absolute/new/evidence/A1 \
  --stock "$STOCK" --pass A1 --slot-map "$SLOT_MAP" --operator "$OPERATOR" \
  --socket "$SOCKET" --attach
"$CLI" roll collect --to /absolute/new/evidence/A2 \
  --stock "$STOCK" --pass A2 --slot-map "$SLOT_MAP" --operator "$OPERATOR" \
  --socket "$SOCKET" --attach
"$CLI" roll collect --to /absolute/new/evidence/B \
  --stock "$STOCK" --pass B --slot-map "$SLOT_MAP" --operator "$OPERATOR" \
  --socket "$SOCKET" --attach
```

Repeat collection for `Arep01` through `Arep10` if those retained artifacts
are part of the evidence package. Review `roll-metadata.json`, receipt settings
fingerprints, exposure lock, clipping results, placement/replay records,
timestamps, exceptions, and `file-hashes.txt`; then run
`shasum -a 256 -c file-hashes.txt` inside each fresh collection directory.

Raw RGB and IR byte lengths are checked against the receipt's actual shape and
dtype. Do not substitute decoded image byte counts for raw file lengths, and
do not claim a physical `189194240`-byte result unless the retained receipt and
file hash support that exact geometry.

The final report must identify app, engine, bridge, CoolscanPy, driver, host,
firmware, adapter, scanner ID, film identity, slot map, all pass tokens, and
operator checkpoints. Historical capture versions remain `Unknown` when the
receipt does not contain them; current collection context must not be presented
as historical capture proof. Until the owner reviews the complete evidence,
the result remains **CALIBRATION NOT COMPLETED / UNVALIDATED**.

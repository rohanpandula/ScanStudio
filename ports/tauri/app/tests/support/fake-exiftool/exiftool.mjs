// Deterministic ExifTool stub (07-01 Task 3) so CI never depends on a real
// ExifTool install. Consumed by the POSIX `exiftool` sh launcher and the
// Windows `exiftool.cmd` batch launcher.
//
// - `exiftool -ver` -> prints "12.76" and exits 0 (the capability probe
//   `exiftool.detect` runs).
// - Any other invocation (a real metadata-apply argument array: `-Tag=value`
//   flags, `-overwrite_original`, then target paths) -> prints the same
//   stdout the real tool prints for a successful single-target apply and
//   exits 0.

const args = process.argv.slice(2);

if (args[0] === "-ver") {
  process.stdout.write("12.76\n");
  process.exit(0);
}

process.stdout.write("    1 image files updated\n");
process.exit(0);

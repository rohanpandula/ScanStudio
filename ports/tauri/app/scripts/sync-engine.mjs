import { execFileSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const appDir = join(scriptDir, "..");
const repoRoot = resolve(appDir, "..");
const engineDir = resolve(
  process.env.SCANSTUDIO_ENGINE_SOURCE ?? join(repoRoot, "vendor", "engine"),
);
const cargoTargetDir = resolve(
  process.env.CARGO_TARGET_DIR ?? join(engineDir, "target"),
);
const engineName = "scanstudio-engine" + (process.platform === "win32" ? ".exe" : "");
const engineBin = join(cargoTargetDir, "release", engineName);

console.log(`[sync-engine] building the bundled engine in ${engineDir}`);
execFileSync(
  "cargo",
  ["build", "--release", "--locked", "--manifest-path", join(engineDir, "Cargo.toml")],
  { cwd: engineDir, env: { ...process.env, CARGO_TARGET_DIR: cargoTargetDir }, stdio: "inherit" },
);

if (!existsSync(engineBin)) {
  console.error(`[sync-engine] ERROR: expected engine binary not found at ${engineBin}`);
  process.exit(1);
}

const triple = execFileSync("rustc", ["--print", "host-tuple"]).toString().trim();
const destName =
  "scanstudio-engine-" + triple + (process.platform === "win32" ? ".exe" : "");

const binariesDir = join(appDir, "src-tauri", "binaries");
mkdirSync(binariesDir, { recursive: true });

const destPath = join(binariesDir, destName);
copyFileSync(engineBin, destPath);
if (process.platform !== "win32") {
  chmodSync(destPath, 0o755);
}

console.log(`[sync-engine] engine staged at ${destPath}`);

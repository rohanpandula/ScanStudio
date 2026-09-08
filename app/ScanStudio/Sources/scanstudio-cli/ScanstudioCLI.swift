// The scanstudio-cli root command (D-07/D-08).
//
// This filename matters: a file literally named "main.swift" is mutually
// exclusive with the attribute below and produces the misleading "needs an
// availability annotation" failure RESEARCH's Spike 1 documents in full
// (## Spike Results, Pitfall 1). The root command carries that attribute
// directly on the struct declaration -- this target never hand-calls
// AsyncParsableCommand's own static entry-point method.

import ArgumentParser
import Foundation
import ScanStudioKit

@main
struct ScanstudioCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scanstudio-cli",
        abstract: "Drives a running ScanStudio app over its local control socket.",
        subcommands: [
            Connect.self, Disconnect.self, Rescan.self, Status.self,
            Frames.self, Settings.self, Outputs.self, Preset.self, Roll.self, Render.self, Export.self, Metadata.self, Diagnostics.self,
            Preview.self, Review.self, Eject.self,
            Scan.self, Stop.self, Resume.self,
            RunJob.self, Schema.self, Doctor.self, Selftest.self,
            Events.self, Sim.self, Session.self, Link.self, Wait.self, Host.self
        ]
    )
}

/// The option group every subcommand carries via `@OptionGroup` (D-09/D-15).
/// JSON is the default output; `--human` opts into text. Omitting
/// `--socket` means the default attach path, `ControlSocketPath.defaultPath()`
/// (`ScanStudioKit/ControlChannelServer.swift`).
struct GlobalOptions: ParsableArguments {
    @Flag(name: .customLong("attach"), help: "Require an existing host; never start one.")
    var attach = false

    @Flag(name: .customLong("headless"), help: "Require or start a headless host.")
    var headless = false
    @Flag(
        name: .customLong("human"),
        help: "Render output as human-readable text instead of JSON."
    )
    private var humanOutput = false

    @Flag(name: .customLong("json"), help: "Render one compact JSON object.")
    private var jsonOutput = false

    @Flag(name: .customLong("ndjson"), help: "Render compact newline-delimited JSON.")
    private var ndjsonOutput = false

    @Option(
        name: .customLong("socket"),
        help: "Path to the control socket. Defaults to the app's standard control socket path."
    )
    var socketPath: String?

    @Option(
        name: .customLong("controller-name"),
        help: "Informational controller label (maximum 128 UTF-8 bytes; grants no authorization)."
    )
    var controllerName: String?

    @Option(
        name: .customLong("key"),
        help: "Idempotency key for mutations (host-memory scope; host restart clears recorded results)."
    )
    var idempotencyKey: String?

    /// D-17: suppresses `--wait`'s stderr progress lines (`scan`, `resume`,
    /// `roll save`). A global flag so a caller never has to remember which
    /// specific subcommands print progress -- every command carries it,
    /// even the ones `--wait` does not apply to, where it is simply unused.
    /// stdout is unaffected either way: it is always exactly one JSON
    /// object.
    @Flag(
        name: .customLong("quiet"),
        help: "Suppress --wait's stderr progress lines. stdout is unaffected -- always exactly one JSON object."
    )
    var quiet = false

    var hostPreference: ControlHostPreference {
        headless ? .headlessOnly : (attach ? .attachOnly : .auto)
    }

    var human: Bool {
        if humanOutput { return true }
        if jsonOutput || ndjsonOutput { return false }
        return ProcessInfo.processInfo.environment["SCANSTUDIO_OUTPUT"] == "human"
    }

    var resolvedControllerName: String {
        controllerName
            ?? ProcessInfo.processInfo.environment["SCANSTUDIO_CONTROLLER"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "scanstudio-cli"
    }

    mutating func validate() throws {
        if attach && headless {
            throw ValidationError("--attach and --headless cannot be used together")
        }
        let explicitFormats = [humanOutput, jsonOutput, ndjsonOutput].count { $0 }
        if explicitFormats > 1 {
            throw ValidationError("--human, --json, and --ndjson are mutually exclusive")
        }
        if explicitFormats == 0,
           let format = ProcessInfo.processInfo.environment["SCANSTUDIO_OUTPUT"],
           !["json", "ndjson", "human"].contains(format) {
            throw ValidationError("SCANSTUDIO_OUTPUT must be json, ndjson, or human")
        }
        if let error = ControlControllerName.validationError(resolvedControllerName) {
            throw ValidationError("invalid controller name: \(error)")
        }
        if let key = idempotencyKey {
            if key.isEmpty || key.utf8.count > 128
                || key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                throw ValidationError("--key must be printable and no longer than 128 UTF-8 bytes")
            }
        }
    }
}

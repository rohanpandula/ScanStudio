// The scanstudio-cli root command (D-07/D-08).
//
// This filename matters: a file literally named "main.swift" is mutually
// exclusive with the attribute below and produces the misleading "needs an
// availability annotation" failure RESEARCH's Spike 1 documents in full
// (## Spike Results, Pitfall 1). The root command carries that attribute
// directly on the struct declaration -- this target never hand-calls
// AsyncParsableCommand's own static entry-point method.

import ArgumentParser
import ScanStudioKit

@main
struct ScanstudioCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scanstudio-cli",
        abstract: "Drives a running ScanStudio app over its local control socket.",
        subcommands: [
            Connect.self, Disconnect.self, Rescan.self, Status.self,
            Frames.self, Settings.self, Outputs.self, Preset.self, Roll.self, Diagnostics.self,
            Preview.self, Review.self, Eject.self,
            Scan.self, Stop.self, Resume.self,
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
    var human = false

    @Option(
        name: .customLong("socket"),
        help: "Path to the control socket. Defaults to the app's standard control socket path."
    )
    var socketPath: String?

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

    mutating func validate() throws {
        if attach && headless {
            throw ValidationError("--attach and --headless cannot be used together")
        }
    }
}

// The scanstudio-cli root command (D-07/D-08).
//
// This filename matters: a file literally named "main.swift" is mutually
// exclusive with the attribute below and produces the misleading "needs an
// availability annotation" failure RESEARCH's Spike 1 documents in full
// (## Spike Results, Pitfall 1). The root command carries that attribute
// directly on the struct declaration -- this target never hand-calls
// AsyncParsableCommand's own static entry-point method.

import ArgumentParser

@main
struct ScanstudioCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scanstudio-cli",
        abstract: "Drives a running ScanStudio app over its local control socket.",
        // Plan 02-06 Task 3 appends events.
        subcommands: [
            Connect.self, Disconnect.self, Rescan.self, Status.self,
            Frames.self, Settings.self, Outputs.self, Roll.self, Diagnostics.self,
            Preview.self, Review.self, Eject.self,
            Scan.self, Stop.self, Resume.self
        ]
    )
}

/// The option group every subcommand carries via `@OptionGroup` (D-09/D-15).
/// JSON is the default output; `--human` opts into text. Omitting
/// `--socket` means the default attach path, `ControlSocketPath.defaultPath()`
/// (`ScanStudioKit/ControlChannelServer.swift`).
struct GlobalOptions: ParsableArguments {
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
}

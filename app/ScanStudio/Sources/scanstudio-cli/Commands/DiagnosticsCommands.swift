// `diagnostics export --to <dir>` -> `diagnostics.export` (D-08/CLI-11).
// The CLI resolves a relative `--to` to an absolute path so a relative
// argument is usable, but performs no other validation and mutates
// nothing on this side: the host validates (absolute, no "..", must
// exist) and performs the actual bundle write through the GUI's own
// diagnostic-bundle code path (T-01-20). Path arithmetic only, below --
// no directory creation, no bundle write, no filename choice.

import ArgumentParser
import Foundation
import ScanStudioKit

struct Diagnostics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnostics",
        abstract: "Export a diagnostics bundle.",
        subcommands: [Export.self]
    )

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "export", abstract: "Write a diagnostics bundle into an existing directory.")

        @OptionGroup var options: GlobalOptions

        @Option(name: .customLong("to"), help: "Directory to write the diagnostics bundle into. Must already exist.")
        var to: String

        func run() async throws {
            try await CommandRunner.run(
                command: "diagnostics.export",
                method: "diagnostics.export",
                params: ControlDiagnosticsExportParams(directory: Self.resolvedAbsolutePath(to)),
                options: options
            )
        }

        /// Resolves `path` to an absolute path client-side only so a
        /// relative `--to` argument is usable -- pure path arithmetic
        /// (`URL(fileURLWithPath:)` resolves against the process's
        /// current directory, `standardizedFileURL` normalizes "." and
        /// ".." components lexically), no filesystem access. The host
        /// still performs the real validation (absolute, no "..",
        /// exists) and the write; the CLI names no filename.
        static func resolvedAbsolutePath(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path
        }
    }
}

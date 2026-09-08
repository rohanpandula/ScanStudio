import ArgumentParser
import Foundation
import ScanStudioKit

struct Session: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Export evidence for the current control session.",
        subcommands: [Export.self]
    )

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Write a create-only ZIP of the current session evidence."
        )

        @OptionGroup var options: GlobalOptions

        @Option(name: .customLong("to"), help: "New ZIP path. Its parent directory must already exist.")
        var to: String

        func run() async throws {
            let command = "session.export"
            let client = try await CommandRunner.openConnection(command: command, options: options)
            let response = try await CommandRunner.requestWithoutParams(
                command: command,
                method: "session.inventory",
                options: options,
                client: client
            )
            guard case .result(let data) = response else {
                try await CommandRunner.finish(
                    command: command,
                    options: options,
                    client: client,
                    response: response
                )
                return
            }

            do {
                let inventory = try JSONDecoder().decode(ControlSessionInventoryResult.self, from: data)
                let entries = try inventory.exportEntries()
                let transcript = try await client.transcriptSnapshot()
                let result = try SessionEvidenceExporter.export(
                    inventory: entries,
                    transcript: transcript,
                    to: URL(fileURLWithPath: to).standardizedFileURL
                )
                try await CommandRunner.finish(
                    command: command,
                    options: options,
                    client: client,
                    response: .result(try JSONEncoder().encode(result))
                )
            } catch {
                try await CommandRunner.fail(
                    command: command,
                    options: options,
                    client: client,
                    error: error
                )
            }
        }
    }
}

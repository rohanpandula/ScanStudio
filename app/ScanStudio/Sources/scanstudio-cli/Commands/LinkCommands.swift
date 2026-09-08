import ArgumentParser
import Foundation
import ScanStudioKit

struct Link: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link", abstract: "Inspect retained USB link observations.",
        subcommands: [Health.self]
    )

    struct Health: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "health", abstract: "Summarize recent telemetry without probing the scanner."
        )
        @OptionGroup var options: GlobalOptions
        @Option(help: "Recent telemetry window in minutes (1–1440).") var minutes: Int = 15

        mutating func validate() throws {
            guard (1...1440).contains(minutes) else {
                throw ValidationError("--minutes must be between 1 and 1440")
            }
        }

        func run() async throws {
            let command = "link.health"
            let client = try await CommandRunner.openConnection(command: command, options: options)
            let response = try await CommandRunner.requestWithoutParams(
                command: command, method: "session.inventory", options: options, client: client
            )
            guard case .result(let data) = response else {
                try await CommandRunner.finish(command: command, options: options, client: client, response: response)
                return
            }
            do {
                let inventory = try JSONDecoder().decode(ControlSessionInventoryResult.self, from: data)
                let entries = try inventory.exportEntries().filter { $0.sourceKind == "bridgeTelemetry" }
                guard entries.count <= 1 else {
                    throw SessionEvidenceExportError.invalidInventory("multiple bridge telemetry sources")
                }
                let snapshot = try entries.first.flatMap { try SessionEvidenceExporter.verifiedSnapshot(of: $0) }
                let result = LinkHealthReport.summarize(snapshot, windowSeconds: Double(minutes) * 60)
                try await CommandRunner.finish(
                    command: command, options: options, client: client,
                    response: .result(try JSONEncoder().encode(result))
                )
            } catch {
                try await CommandRunner.fail(command: command, options: options, client: client, error: error)
            }
        }
    }
}

import ArgumentParser
import ScanStudioKit

/// Simulator setup only; the engine refuses this method for real devices.
struct Sim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sim", abstract: "Configure simulated media without scanner motion.",
        subcommands: [LoadMedia.self]
    )

    struct LoadMedia: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "load-media")
        @OptionGroup var options: GlobalOptions
        @Option(help: "Simulated carrier: strip6 or roll36.") var carrier = "strip6"
        @Option(help: "Preview fixture: textured or boundaryAndBlank.") var previewFixture: String?
        @Option(help: "Simulate a batch failure at this frame.") var abortAtFrame: Int?
        @Option(help: "Typed simulator failure code.") var abortCode: String?

        func run() async throws {
            try await CommandRunner.run(
                command: "sim.loadMedia", method: "sim.loadMedia",
                params: LoadMediaParams(
                    carrier: carrier, previewFixture: previewFixture,
                    abortAtFrame: abortAtFrame, abortCode: abortCode
                ), options: options
            )
        }
    }
}

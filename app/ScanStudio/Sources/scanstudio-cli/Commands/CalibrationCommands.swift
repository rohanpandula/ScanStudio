import ArgumentParser
import Foundation
import ScanStudioKit

extension Roll {
    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "verify", abstract: "Check retained capture evidence and optional exposure/clipping requirements.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "Restrict checks to this exact pass token; otherwise compare exposures within each pass.")
        var pass: String?
        @Flag(name: .customLong("exposure-identical")) var exposureIdentical = false
        @Flag(name: .customLong("no-clipping")) var noClipping = false

        func run() async throws {
            let client = try await CommandRunner.openConnection(command: "roll.verify", options: options)
            let response = try await CommandRunner.request(
                command: "roll.verify", method: "roll.verify",
                params: ControlRollVerifyParams(pass: pass, exposureIdentical: exposureIdentical, noClipping: noClipping),
                options: options, client: client
            )
            var verified = false
            if case .result(let data) = response {
                do {
                    verified = try JSONDecoder().decode(CalibrationVerificationReport.self, from: data).status == "pass"
                } catch {
                    try await CommandRunner.fail(command: "roll.verify", options: options, client: client, error: error)
                }
            }
            try await CommandRunner.finish(command: "roll.verify", options: options, client: client, response: response)
            if !verified { throw ExitCode(ControlCLIExitCode.engineOrGateError.rawValue) }
        }
    }

    struct Collect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "collect", abstract: "Copy and hash one calibration pass into a new directory.")
        @OptionGroup var options: GlobalOptions
        @Option(help: "New destination directory; existing destinations are refused.") var to: String
        @Option(help: "Film stock used in exported filenames.") var stock: String
        @Option(help: "Exact receipt pass token.") var pass: String
        @Option(name: .customLong("slot-map"), help: "JSON file mapping scanner slots to physical frame numbers, e.g. {\"1\":1,\"2\":2}.")
        var slotMap: String
        @Option(name: .customLong("operator"), help: "Operator name recorded in collection metadata.") var operatorName: String?

        func run() async throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: slotMap))
            let mapping = try JSONDecoder().decode([String: Int].self, from: data)
            guard !mapping.isEmpty,
                  mapping.allSatisfy({ key, value in
                      guard let slot = UInt32(key) else { return false }
                      return slot > 0 && String(slot) == key && value > 0 && UInt64(value) <= UInt64(UInt32.max)
                  }),
                  Set(mapping.values).count == mapping.count else {
                throw ValidationError("--slot-map must map unique positive scanner slots to unique positive physical frames.")
            }
            try await CommandRunner.run(
                command: "roll.collect", method: "roll.collect",
                params: ControlRollCollectParams(
                    to: URL(fileURLWithPath: to).standardizedFileURL.path,
                    metadata: CalibrationCollectionMetadata(stock: stock, pass: pass, slotMap: mapping, operatorName: operatorName)
                ), options: options
            )
        }
    }
}

import ArgumentParser
import Foundation
import ScanStudioKit

extension Roll {
    struct Report: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "report",
            abstract: "Write a create-only HTML contact sheet for a retained roll."
        )

        @OptionGroup var options: GlobalOptions

        @Argument(help: "Saved roll directory containing manifest.json.")
        var directory: String

        @Option(name: .customLong("to"), help: "New HTML file path. Defaults to DIRECTORY/report.html.")
        var destination: String?

        func run() async throws {
            do {
                let result = try RollHTMLReport.write(
                    projectDirectory: URL(fileURLWithPath: directory),
                    destination: destination.map(URL.init(fileURLWithPath:))
                )
                let output = try ControlCLIOutput.renderResult(
                    command: "roll.report",
                    resultJSON: [
                        "path": result.path,
                        "frameCount": result.frameCount,
                        "receiptCount": result.receiptCount,
                        "embeddedThumbnailCount": result.embeddedThumbnailCount,
                    ],
                    human: options.human
                )
                print(output, terminator: "")
            } catch {
                let payload = ControlErrorPayload(
                    code: ControlErrorCode.invalidParams.rawValue,
                    message: "\"roll report\" failed: \(error.localizedDescription)",
                    recoverable: false
                )
                let output = try ControlCLIOutput.renderError(
                    command: "roll.report",
                    payload: payload,
                    human: options.human
                )
                print(output, terminator: "")
                throw ExitCode(ControlCLIExitCode.usage.rawValue)
            }
        }
    }
}

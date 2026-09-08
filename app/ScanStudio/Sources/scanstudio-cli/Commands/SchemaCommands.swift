import ArgumentParser
import Foundation
import ScanStudioKit

/// An offline contract inventory, derived from the command configurations and
/// Codable recipes used by the executable. No host connection is needed.
struct Schema: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "schema", abstract: "Describe commands, job input, preflight gates, and exit codes as JSON.")
    @OptionGroup var options: GlobalOptions

    func run() async throws {
        func json<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        func commands(_ types: [ParsableCommand.Type], prefix: String = "") -> [[String: Any]] {
            types.flatMap { type -> [[String: Any]] in
                guard let name = type.configuration.commandName else { return [] }
                let path = prefix.isEmpty ? name : "\(prefix) \(name)"
                return [["command": path, "description": type.configuration.abstract,
                         "help": type.helpMessage()]] + commands(type.configuration.subcommands, prefix: path)
            }
        }
        let output = OutputRecipe(
            archive: ArchiveRecipe(filenameTemplate: "Archive_####", destination: "/tmp/scanstudio-job/archive"),
            rawExport: RawExportRecipe(destination: "/tmp/scanstudio-job/raw"),
            positive: PositiveRecipe(enabled: false, fileFormat: .tiff, colorProfile: .adobeRgb1998, filenameTemplate: "Positive_####", destination: "/tmp/scanstudio-job/positive"),
            preview: PreviewRecipe(enabled: true, fileFormat: .jpeg, maxLongEdgePx: 1024, filenameTemplate: "Preview_####", destination: "/tmp/scanstudio-job/preview")
        )
        let example: [String: Any] = [
            "schemaVersion": 1, "deviceId": "sim-ls5000-0",
            "roll": ["name": "Example", "carrier": "strip6", "frameCount": 6, "filmProcess": "positive"],
            "frames": [1],
            "capture": try json(CaptureRecipe(resolutionDpi: 4000, bitDepth: 16, multisamplePasses: 4, channels: "rgbi")),
            "processing": try json(ProcessingRecipe(filmProcess: .positive, autofocusEachFrame: true, autoExposureEachFrame: true, digitalIceEnabled: false, digitalIceMode: .legacy)),
            "outputs": try json(output),
            "confirmations": ["filmLoaded": false, "motion": false],
            "autoApprove": false, "wait": true,
        ]
        // Keep the published example inside the same validation boundary as run.
        _ = try ScanJobDocument.decode(JSONSerialization.data(withJSONObject: example))
        let exits: [(String, ControlCLIExitCode)] = [
            ("success", .success), ("usage", .usage), ("engineOrGateError", .engineOrGateError),
            ("noHostReachable", .noHostReachable), ("internalError", .internalError),
            ("busy", .busy), ("hostExited", .hostExited), ("confirmationRequired", .confirmationRequired),
            ("schemaVersionMismatch", .schemaVersionMismatch), ("waitTimedOut", .waitTimedOut),
        ]
        let result: [String: Any] = [
            "controlSchemaVersion": ControlSchema.version,
            "commands": commands(ScanstudioCLI.configuration.subcommands),
            "job": [
                "schemaVersion": 1, "maximumBytes": 1_048_576,
                "required": ["schemaVersion", "deviceId", "roll", "frames", "capture", "processing", "outputs", "confirmations"],
                "optional": ["autoApprove", "wait"],
                "constraints": ["Unknown top-level fields are rejected.", "Frames must be unique and within roll.frameCount (1...10000).", "Roll and processing filmProcess must agree.", "Imported exposureOverride10ns is refused.", "Actual runs require document confirmations and CLI motion/film flags."],
                "carriers": SimulatedFilmCarrier.allCases.map(\.rawValue),
                "filmProcesses": FilmProcess.allCases.map(\.rawValue),
                "example": example,
            ],
            "preflight": ["ready": "Bool", "frames": "[Int]", "estimatedBytes": "UInt64", "checks": [["code": "String", "passed": "Bool", "guidance": "String"]]],
            "error": ["code": "String", "message": "String", "recoverable": "Bool", "guidance": "String?", "gate": "String?"],
            "exitCodes": Dictionary(uniqueKeysWithValues: exits.map { ($0.0, $0.1.rawValue) }),
            "note": "Command help describes accepted arguments. Job recipes use the same JSON fields as settings and outputs. Dry-run is observational; a later admission rechecks live gates.",
        ]
        print(try ControlCLIOutput.renderResult(command: "schema", resultJSON: result, human: options.human), terminator: "")
    }
}

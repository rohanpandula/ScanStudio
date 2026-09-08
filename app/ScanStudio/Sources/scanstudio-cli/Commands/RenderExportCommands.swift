import ArgumentParser
import Foundation
import ScanStudioKit

private func parseFrameSpecs(_ specs: [String]) throws -> [Int] {
    guard !specs.isEmpty else { throw ValidationError("at least one --frame is required") }
    var result: [Int] = []
    for spec in specs {
        let pieces = spec.split(separator: "-", omittingEmptySubsequences: true)
        guard pieces.count == 1 || pieces.count == 2,
              let first = Int(pieces[0]), first > 0 else {
            throw ValidationError("--frame must be a positive number or inclusive range such as 3-6")
        }
        let last = pieces.count == 2 ? Int(pieces[1]) : first
        guard let last, last >= first else {
            throw ValidationError("--frame range must end at or after its start")
        }
        result.append(contentsOf: first...last)
    }
    return Array(Set(result)).sorted()
}

struct Render: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "render", abstract: "Re-render positives from retained masters without scanner motion.")
    @OptionGroup var options: GlobalOptions
    @Option(name: .customLong("frame"), help: "Frame number or inclusive range; repeat for multiple selections.") var frame: [String]
    @Option(help: "Output profile: sRGB, AdobeRGB1998, or ProPhotoRGB.") var profile: String
    @Option(help: "New output directory.") var output: String

    func run() async throws {
        try await CommandRunner.run(
            command: "render", method: "roll.render",
            params: ControlRollRenderParams(frames: try parseFrameSpecs(frame), profile: profile, output: URL(fileURLWithPath: output).standardizedFileURL.path),
            options: options
        )
    }
}

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Copy retained outputs into a new create-only directory.")
    @OptionGroup var options: GlobalOptions
    @Option(help: "New destination directory; an existing directory is refused.") var to: String
    @Option(help: "One relative filename pattern, using # for the frame number.") var template: String
    @Option(help: "Artifact kind: positive, raw, or master.") var kind: String
    @Option(name: .customLong("frame"), help: "Optional frame number or inclusive range; repeat for multiple selections.") var frame: [String] = []

    func run() async throws {
        let frames = frame.isEmpty ? nil : try parseFrameSpecs(frame)
        try await CommandRunner.run(
            command: "export", method: "roll.export",
            params: ControlRollExportParams(to: URL(fileURLWithPath: to).standardizedFileURL.path, template: template, kind: kind, frames: frames),
            options: options
        )
    }
}

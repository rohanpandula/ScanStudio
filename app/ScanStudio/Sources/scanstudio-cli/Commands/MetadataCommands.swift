import ArgumentParser
import Foundation
import ScanStudioKit

struct Metadata: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metadata",
        abstract: "Apply roll metadata to new output copies.",
        subcommands: [Apply.self]
    )

    struct Apply: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "apply",
            abstract: "Preview or apply EXIF metadata to create-only output copies."
        )

        @OptionGroup var options: GlobalOptions
        @Option(name: .customLong("frame"), help: "Frame number; repeat for selected frames.") var frame: [Int]
        @Option(help: "New destination directory; an existing directory is refused.") var to: String
        @Option(help: "One relative filename pattern using # for the frame number.") var template: String
        @Option(help: "Artifact kind: positive, raw, or master.") var kind: String = "positive"
        @Option(name: .customLong("film-stock")) var filmStock: String?
        @Option var camera: String?
        @Option var lens: String?
        @Option var date: String?
        @Option var notes: String?
        @Flag(name: .customLong("dry-run"), help: "Show the approved ExifTool command without creating files.") var dryRun = false

        func validate() throws {
            guard !frame.isEmpty, frame.allSatisfy({ $0 > 0 }) else {
                throw ValidationError("at least one positive --frame is required")
            }
            guard ["positive", "raw", "master"].contains(kind.lowercased()) else {
                throw ValidationError("--kind must be positive, raw, or master")
            }
            if let date, date.isEmpty || date.count > 32 {
                throw ValidationError("--date must be a non-empty ISO date value")
            }
        }

        func run() async throws {
            let metadata = MetadataSet(
                camera: camera,
                lens: lens,
                filmStock: filmStock,
                date: date.map(PartialDate.exact(date:)),
                notes: notes
            )
            try await CommandRunner.run(
                command: "metadata.apply",
                method: "roll.metadataApply",
                params: ControlRollMetadataApplyParams(
                    frames: Array(Set(frame)).sorted(),
                    to: URL(fileURLWithPath: to).standardizedFileURL.path,
                    template: template,
                    kind: kind,
                    metadata: metadata,
                    dryRun: dryRun
                ),
                options: options
            )
        }
    }
}

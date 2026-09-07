// `roll save|open|list` (D-08/CLI-07).

import ArgumentParser
import Foundation
import ScanStudioKit

struct Roll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "roll",
        abstract: "Save, open, or list rolls (projects).",
        subcommands: [Save.self, Open.self, List.self]
    )

    /// `roll save` -> `roll.save`.
    ///
    /// SAFETY FINDING (see this plan's `<safety_finding>`): this routes to
    /// `SessionModel.saveRollAndScanSelectedFrames(name:carrier:
    /// frameCount:filmProcess:)` (SessionModel.swift:2762-2795), which
    /// creates the project and immediately calls
    /// `startScanOrRequestManualReview(frames:)` -- it moves film. D-08's
    /// literal subcommand tree names no confirmation flag for `roll save`,
    /// but PROJECT.md's standing "no scanner motion without an explicit
    /// confirmation flag" constraint applies anyway, mirroring Phase 1's
    /// identical tightening of `review.approve` beyond its own literal
    /// enumeration. `--confirm-motion` is required here, at parse time,
    /// before any socket is opened -- a CLI-level tightening beyond the
    /// channel's own params (T-02-27's parse-time layer; the wire's own
    /// `motionConfirmed` gate, plan 02-01 Task 3, is the independent
    /// second layer). A missing flag prints a CONFIRMATION_REQUIRED body
    /// and exits 77, exactly like the channel's own refusal for the
    /// identical condition -- before any connection exists.
    struct Save: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "save",
            abstract: "Create the project from the current preview and scan the selected frames. Requires --confirm-motion."
        )

        @OptionGroup var options: GlobalOptions

        @Option(name: .customLong("name"), help: "Roll/project name.")
        var name: String

        @Option(name: .customLong("carrier"), help: "Film carrier: mounted, strip6, or roll36.", transform: {
            guard let value = SimulatedFilmCarrier(rawValue: $0) else {
                throw ValidationError("carrier must be one of: \(SimulatedFilmCarrier.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return value
        })
        var carrier: SimulatedFilmCarrier

        @Option(name: .customLong("frame-count"), help: "Frame count for this carrier.")
        var frameCount: Int

        @Option(name: .customLong("film-process"), help: "Film process: positive, c41ColorNegative, bwNegative, or kodachrome.", transform: {
            guard let value = FilmProcess(rawValue: $0) else {
                throw ValidationError("film-process must be one of: \(FilmProcess.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return value
        })
        var filmProcess: FilmProcess

        @Flag(name: .customLong("confirm-motion"), help: "Required: this command starts a scan.")
        var confirmMotion = false

        mutating func validate() throws {
            guard confirmMotion else {
                let payload = ControlErrorPayload(
                    .confirmationRequired,
                    message: "\"roll save\" requires --confirm-motion (it creates the project and starts the scan).",
                    guidance: "Confirm scanner motion is authorized, then retry with --confirm-motion."
                )
                let text = try ControlCLIOutput.renderError(command: "roll.save", payload: payload, human: options.human)
                print(text, terminator: "")
                throw ExitCode(77)
            }
        }

        func run() async throws {
            try await CommandRunner.run(
                command: "roll.save",
                method: "roll.save",
                params: RollSaveWireParams(name: name, carrier: carrier, frameCount: frameCount, filmProcess: filmProcess, motionConfirmed: true),
                options: options
            )
        }
    }

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "open", abstract: "Open a saved roll by its project directory.")

        @OptionGroup var options: GlobalOptions

        @Argument(help: "Project directory to open.")
        var directory: String

        func run() async throws {
            try await CommandRunner.run(
                command: "roll.open",
                method: "roll.open",
                params: ControlRollOpenParams(directory: directory),
                options: options
            )
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List recent rolls (projects).")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await CommandRunner.runWithoutParams(command: "roll.list", method: "roll.list", options: options)
        }
    }
}

/// `ControlRollSaveParams` (ScanStudioKit/ControlWireProtocol.swift) drops
/// its own public initializer -- like every confirmation-bearing params
/// struct, it declares only the compiler's memberwise one, which is
/// `internal` and therefore invisible across this plain `import
/// ScanStudioKit` module boundary (only `@testable import` sees it). This
/// mirror is this file's own encode-direction twin, matching
/// `ControlWireProtocol.swift`'s own documented rationale for
/// `ControlScanProgress`/`ControlProjectSummary`: rather than retrofitting
/// a public initializer onto a type owned elsewhere, a small local mirror
/// with the identical field names (so its synthesized `Encodable`
/// produces byte-identical wire JSON) is the correct fix here.
private struct RollSaveWireParams: Encodable {
    let name: String
    let carrier: SimulatedFilmCarrier
    let frameCount: Int
    let filmProcess: FilmProcess
    let motionConfirmed: Bool
}

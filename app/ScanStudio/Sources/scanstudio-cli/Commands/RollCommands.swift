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

        @Flag(name: .customLong("wait"), help: "Block until the job reaches a terminal state, observed on the event stream -- never polled.")
        var wait = false

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

        /// D-17: `roll save --wait` runs through the same `MotionStartRunner`
        /// body `scan --wait`/`resume --wait` use -- same subscribe-first
        /// ordering, same `JobWaiter`, same terminal-state exit codes, no
        /// second wait implementation. Without `--wait`, `roll save` keeps
        /// its original single-request `CommandRunner.run` path unchanged:
        /// `MotionStartRunner`'s own `!wait` branch renders `job.get`'s
        /// aggregate instead of the start request's own result (the right
        /// call for `scan.start`/`scan.resume`, whose own result is an
        /// uninteresting `{}`) -- but `roll.save`'s own result
        /// (`{saved, projectName, projectDirectory}`) is the useful,
        /// documented body this command has always returned, and routing
        /// it through that branch would silently replace it with an
        /// unrelated `job.get` shape. `roll save` without `--wait`
        /// therefore never needs `JobWaiter` at all.
        func run() async throws {
            guard wait else {
                try await CommandRunner.run(
                    command: "roll.save",
                    method: "roll.save",
                    params: ControlRollSaveParams(name: name, carrier: carrier, frameCount: frameCount, filmProcess: filmProcess, motionConfirmed: true),
                    options: options
                )
                return
            }
            try await MotionStartRunner.run(
                command: "roll.save",
                method: "roll.save",
                params: ControlRollSaveParams(name: name, carrier: carrier, frameCount: frameCount, filmProcess: filmProcess, motionConfirmed: true),
                options: options,
                wait: wait,
                quiet: options.quiet
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

// WR-05: the hand-duplicated `RollSaveWireParams` mirror that used to live
// here is gone -- `ControlWireProtocol.swift`'s own canonical
// `ControlRollSaveParams` now has an explicit `public init`, so `Save
// .run()` above constructs it directly.

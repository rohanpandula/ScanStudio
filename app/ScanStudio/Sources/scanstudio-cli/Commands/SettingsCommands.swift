// `settings get|set` and `outputs get|set` (D-08/CLI-06). Both `Set`s are
// read-modify-write on one connection: send the matching `get`, decode the
// current recipe(s), apply only the options the operator actually
// supplied, and send the `set`. `Bool?`-valued flags (ArgumentParser's
// `.prefixedNo` inversion) keep "not supplied" distinguishable from
// `false` -- a flag defaulting to `false` would silently turn a feature
// off on every invocation. `--from-json <path>` replaces the whole recipe
// object before the named overrides are applied, so a field CLI-06 does
// not enumerate is still reachable; named overrides win when both are
// given. No value is validated beyond JSON decodability -- the host
// applies the GUI's own validation, and duplicating it here would be a
// second source of truth.

import ArgumentParser
import Foundation
import ScanStudioKit

struct Settings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Get or set capture and processing settings.",
        subcommands: [Get.self, Set.self]
    )

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "get", abstract: "Report current capture and processing settings.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await CommandRunner.runWithoutParams(command: "settings.get", method: "settings.get", options: options)
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Read-modify-write the current capture and processing settings.")

        @OptionGroup var options: GlobalOptions

        @Option(name: .customLong("from-json"), help: "Path to a JSON object with \"capture\" and \"processing\" keys that replaces both recipes before any named override below is applied.")
        var fromJSON: String?

        @Option(name: .customLong("resolution"), help: "Capture resolution in DPI (resolutionDpi).")
        var resolution: Int?
        @Option(name: .customLong("bit-depth"), help: "Capture bit depth (bitDepth).")
        var bitDepth: Int?
        @Option(name: .customLong("multisample"), help: "Multisample pass count (multisamplePasses).")
        var multisample: Int?
        @Option(name: .customLong("channels"), help: "Capture channel set, e.g. \"rgb\" or \"rgbi\".")
        var channels: String?

        @Option(name: .customLong("film-process"), help: "Film process: positive, c41ColorNegative, bwNegative, or kodachrome.", transform: {
            guard let value = FilmProcess(rawValue: $0) else {
                throw ValidationError("film-process must be one of: \(FilmProcess.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return value
        })
        var filmProcess: FilmProcess? = nil

        @Flag(name: .customLong("autofocus"), inversion: .prefixedNo, help: "Enable or disable per-frame autofocus (autofocusEachFrame).")
        var autofocus: Bool?
        @Flag(name: .customLong("auto-exposure"), inversion: .prefixedNo, help: "Enable or disable per-frame auto exposure (autoExposureEachFrame).")
        var autoExposure: Bool?
        @Flag(name: .customLong("digital-ice"), inversion: .prefixedNo, help: "Enable or disable Digital ICE dust/scratch removal (digitalIceEnabled).")
        var digitalIce: Bool?

        @Option(name: .customLong("digital-ice-mode"), help: "Digital ICE mode: legacy or hybrid.", transform: {
            guard let value = DigitalIceMode(rawValue: $0) else {
                throw ValidationError("digital-ice-mode must be one of: \(DigitalIceMode.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return value
        })
        var digitalIceMode: DigitalIceMode? = nil

        func run() async throws {
            let client = try await CommandRunner.openConnection(command: "settings.set", options: options)
            let getResponse = try await CommandRunner.requestWithoutParams(command: "settings.set", method: "settings.get", options: options, client: client)
            guard case .result(let data) = getResponse else {
                try await CommandRunner.finish(command: "settings.set", options: options, client: client, response: getResponse)
                return
            }

            var current: ControlSettingsResult
            do {
                if let fromJSON {
                    let jsonData = try Data(contentsOf: URL(fileURLWithPath: fromJSON))
                    current = try JSONDecoder().decode(ControlSettingsResult.self, from: jsonData)
                } else {
                    current = try JSONDecoder().decode(ControlSettingsResult.self, from: data)
                }
            } catch {
                try await CommandRunner.fail(command: "settings.set", options: options, client: client, error: error)
            }

            let capture = CaptureRecipe(
                resolutionDpi: resolution ?? current.capture.resolutionDpi,
                bitDepth: bitDepth ?? current.capture.bitDepth,
                multisamplePasses: multisample ?? current.capture.multisamplePasses,
                channels: channels ?? current.capture.channels
            )
            let processing = ProcessingRecipe(
                filmProcess: filmProcess ?? current.processing.filmProcess,
                autofocusEachFrame: autofocus ?? current.processing.autofocusEachFrame,
                autoExposureEachFrame: autoExposure ?? current.processing.autoExposureEachFrame,
                digitalIceEnabled: digitalIce ?? current.processing.digitalIceEnabled,
                digitalIceMode: digitalIceMode ?? current.processing.digitalIceMode,
                softwareDustRemovalBw: current.processing.softwareDustRemovalBw
            )

            let response = try await CommandRunner.request(
                command: "settings.set",
                method: "settings.set",
                params: ControlSettingsSetParams(capture: capture, processing: processing),
                options: options,
                client: client
            )
            try await CommandRunner.finish(command: "settings.set", options: options, client: client, response: response)
        }
    }
}

struct Outputs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "outputs",
        abstract: "Get or set output recipes.",
        subcommands: [Get.self, Set.self]
    )

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "get", abstract: "Report the current output recipe.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await CommandRunner.runWithoutParams(command: "outputs.get", method: "outputs.get", options: options)
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Read-modify-write the current output recipe.")

        @OptionGroup var options: GlobalOptions

        @Option(name: .customLong("from-json"), help: "Path to a JSON OutputRecipe that replaces the whole recipe before any named override below is applied.")
        var fromJSON: String?

        @Flag(name: .customLong("master-enabled"), inversion: .prefixedNo, help: "Enable or disable the archive master (archive.enabled).")
        var masterEnabled: Bool?
        @Option(name: .customLong("master-destination"), help: "Archive master output directory (archive.destination).")
        var masterDestination: String?

        @Flag(name: .customLong("raw-enabled"), inversion: .prefixedNo, help: "Enable or disable the raw negative export (rawExport.enabled).")
        var rawEnabled: Bool?
        @Option(name: .customLong("raw-destination"), help: "Raw negative export directory (rawExport.destination).")
        var rawDestination: String?

        @Flag(name: .customLong("positive-enabled"), inversion: .prefixedNo, help: "Enable or disable the positive derivative (positive.enabled).")
        var positiveEnabled: Bool?
        @Option(name: .customLong("positive-destination"), help: "Positive derivative output directory (positive.destination).")
        var positiveDestination: String?

        @Flag(name: .customLong("preview-enabled"), inversion: .prefixedNo, help: "Enable or disable the preview derivative (preview.enabled).")
        var previewEnabled: Bool?
        @Option(name: .customLong("preview-destination"), help: "Preview derivative output directory (preview.destination).")
        var previewDestination: String?

        func run() async throws {
            let client = try await CommandRunner.openConnection(command: "outputs.set", options: options)
            let getResponse = try await CommandRunner.requestWithoutParams(command: "outputs.set", method: "outputs.get", options: options, client: client)
            guard case .result(let data) = getResponse else {
                try await CommandRunner.finish(command: "outputs.set", options: options, client: client, response: getResponse)
                return
            }

            var current: OutputRecipe
            do {
                if let fromJSON {
                    let jsonData = try Data(contentsOf: URL(fileURLWithPath: fromJSON))
                    current = try JSONDecoder().decode(OutputRecipe.self, from: jsonData)
                } else {
                    current = try JSONDecoder().decode(ControlOutputsResult.self, from: data).outputs
                }
            } catch {
                try await CommandRunner.fail(command: "outputs.set", options: options, client: client, error: error)
            }

            let updated = OutputRecipe(
                archive: ArchiveRecipe(
                    enabled: masterEnabled ?? current.archive.enabled,
                    filenameTemplate: current.archive.filenameTemplate,
                    destination: masterDestination ?? current.archive.destination,
                    fullCapturePackage: current.archive.fullCapturePackage
                ),
                rawExport: RawExportRecipe(
                    enabled: rawEnabled ?? current.rawExport.enabled,
                    fileFormat: current.rawExport.fileFormat,
                    tiffInfrared: current.rawExport.tiffInfrared,
                    filenameTemplate: current.rawExport.filenameTemplate,
                    destination: rawDestination ?? current.rawExport.destination
                ),
                positive: PositiveRecipe(
                    enabled: positiveEnabled ?? current.positive.enabled,
                    fileFormat: current.positive.fileFormat,
                    colorProfile: current.positive.colorProfile,
                    filenameTemplate: current.positive.filenameTemplate,
                    destination: positiveDestination ?? current.positive.destination
                ),
                preview: PreviewRecipe(
                    enabled: previewEnabled ?? current.preview.enabled,
                    fileFormat: current.preview.fileFormat,
                    maxLongEdgePx: current.preview.maxLongEdgePx,
                    filenameTemplate: current.preview.filenameTemplate,
                    destination: previewDestination ?? current.preview.destination
                ),
                autoCrop: current.autoCrop,
                c41Render: current.c41Render
            )

            let response = try await CommandRunner.request(
                command: "outputs.set",
                method: "outputs.set",
                params: ControlOutputsSetParams(outputs: updated),
                options: options,
                client: client
            )
            try await CommandRunner.finish(command: "outputs.set", options: options, client: client, response: response)
        }
    }
}

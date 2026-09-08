import ArgumentParser
import Foundation
import ScanStudioKit

struct Preset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preset",
        abstract: "Save, list, or apply named scan and output recipes.",
        subcommands: [Save.self, List.self, Apply.self]
    )

    struct Save: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "save", abstract: "Save the current scan and output settings under a name.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Preset name.") var name: String

        func run() async throws {
            let client = try await CommandRunner.openConnection(command: "preset.save", options: options)
            let settingsResponse = try await CommandRunner.requestWithoutParams(command: "preset.save", method: "settings.get", options: options, client: client)
            let settingsData: Data
            switch settingsResponse {
            case .result(let data): settingsData = data
            case .failure:
                try await CommandRunner.finish(command: "preset.save", options: options, client: client, response: settingsResponse)
                return
            }
            let outputsResponse = try await CommandRunner.requestWithoutParams(command: "preset.save", method: "outputs.get", options: options, client: client)
            let outputsData: Data
            switch outputsResponse {
            case .result(let data): outputsData = data
            case .failure:
                try await CommandRunner.finish(command: "preset.save", options: options, client: client, response: outputsResponse)
                return
            }
            let settings: ControlSettingsResult
            let outputs: ControlOutputsResult
            do {
                settings = try JSONDecoder().decode(ControlSettingsResult.self, from: settingsData)
                outputs = try JSONDecoder().decode(ControlOutputsResult.self, from: outputsData)
            } catch {
                try await CommandRunner.fail(command: "preset.save", options: options, client: client, error: error)
            }
            do {
                try ScanRecipePresetStore().save(ScanRecipePresetDocument(
                    name: name,
                    capture: settings.capture,
                    processing: settings.processing,
                    output: outputs.outputs
                ))
            } catch {
                await client.shutdown()
                try PresetCommandSupport.failLocal(command: "preset.save", options: options, error: error)
            }
            let result = try ControlCLIOutput.renderResult(command: "preset.save", resultJSON: ["name": name], human: options.human, context: await client.cliEnvelopeContext)
            print(result, terminator: "")
            await client.shutdown()
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List saved preset names without contacting the scanner.")
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            do {
                let names = try ScanRecipePresetStore().list()
                let result = try ControlCLIOutput.renderResult(command: "preset.list", resultJSON: ["presets": names], human: options.human)
                print(result, terminator: "")
            } catch {
                try PresetCommandSupport.failLocal(command: "preset.list", options: options, error: error)
            }
        }
    }

    struct Apply: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "apply", abstract: "Apply a saved preset without moving the scanner.")
        @OptionGroup var options: GlobalOptions
        @Argument(help: "Preset name.") var name: String

        func run() async throws {
            try await PresetCommandSupport.apply(name: name, options: options, command: "preset.apply")
        }
    }
}

enum PresetCommandSupport {
    static func apply(name: String, options: GlobalOptions, command: String, emitResult: Bool = true, existingClient: ControlChannelClient? = nil) async throws {
        let preset: ScanRecipePresetDocument
        do {
            preset = try ScanRecipePresetStore().load(named: name)
        } catch {
            try failLocal(command: command, options: options, error: error)
        }

        let client: ControlChannelClient
        if let existingClient { client = existingClient }
        else { client = try await CommandRunner.openConnection(command: command, options: options) }
        let settingsResponse = try await CommandRunner.requestWithoutParams(command: command, method: "settings.get", options: options, client: client)
        let currentSettings: ControlSettingsResult
        switch settingsResponse {
        case .result(let data):
            do { currentSettings = try JSONDecoder().decode(ControlSettingsResult.self, from: data) }
            catch { try await CommandRunner.fail(command: command, options: options, client: client, error: error) }
        case .failure:
            try await CommandRunner.finish(command: command, options: options, client: client, response: settingsResponse)
            return
        }

        // The preset stores the effective recipe for portability. The live
        // project remains the authority for a persisted manual exposure lock.
        let capture = CaptureRecipe(
            resolutionDpi: preset.capture.resolutionDpi,
            bitDepth: preset.capture.bitDepth,
            multisamplePasses: preset.capture.multisamplePasses,
            channels: preset.capture.channels,
            exposureOverride10ns: currentSettings.capture.exposureOverride10ns
        )
        let settingsSet = try await CommandRunner.request(
            command: command,
            method: "settings.set",
            params: ControlSettingsSetParams(capture: capture, processing: preset.processing),
            options: options,
            client: client
        )
        if case .failure = settingsSet {
            try await CommandRunner.finish(command: command, options: options, client: client, response: settingsSet)
            return
        }
        let outputsSet = try await CommandRunner.request(
            command: command,
            method: "outputs.set",
            params: ControlOutputsSetParams(outputs: preset.output),
            options: options,
            client: client
        )
        if case .failure = outputsSet {
            try await CommandRunner.finish(command: command, options: options, client: client, response: outputsSet)
            return
        }
        if emitResult {
            let result = try ControlCLIOutput.renderResult(command: command, resultJSON: ["name": name], human: options.human, context: await client.cliEnvelopeContext)
            print(result, terminator: "")
        }
        if existingClient == nil { await client.shutdown() }
    }

    static func failLocal(command: String, options: GlobalOptions, error: Error) throws -> Never {
        let payload = ControlErrorPayload(
            code: ControlErrorCode.invalidParams.rawValue,
            message: "\"\(command)\" failed: \(error)",
            recoverable: false
        )
        let result = try ControlCLIOutput.renderError(command: command, payload: payload, human: options.human)
        print(result, terminator: "")
        throw ExitCode(ControlCLIExitCode.usage.rawValue)
    }
}

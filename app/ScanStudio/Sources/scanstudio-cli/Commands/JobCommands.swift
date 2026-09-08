import ArgumentParser
import Darwin
import Foundation
import ScanStudioKit

/// Executes one locally validated, human-approved declarative roll job.
struct RunJob: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Validate and execute a declarative scan job."
    )

    @OptionGroup var options: GlobalOptions

    @Argument(help: "Versioned JSON job document.")
    var jobPath: String

    @Flag(name: .customLong("dry-run"), help: "Evaluate the job and current read-only scan gates without starting a host or changing state.")
    var dryRun = false

    @Flag(name: .customLong("film-loaded"), help: "Required for execution: confirms film is physically loaded.")
    var filmLoaded = false

    @Flag(name: .customLong("confirm-motion"), help: "Required for execution: confirms scanner motion is authorized.")
    var confirmMotion = false

    @Flag(name: .customLong("allow-unverified-hardware"), help: "Allow the job's recognized but unverified scanner.")
    var allowUnverifiedHardware = false

    func run() async throws {
        let job = try loadJob()
        if dryRun {
            try await runDryRun(job)
            return
        }
        try requireExecutionConfirmations(job)
        FileHandle.standardError.write(try job.normalizedJSON() + Data("\n".utf8))
        _ = try await RollRun.run(
            name: job.roll.name,
            carrier: job.roll.carrier,
            requestedFrameCount: job.roll.frameCount,
            filmProcess: job.roll.filmProcess,
            skipBlank: false,
            autoApprove: job.autoApprove ?? false,
            wait: job.wait ?? true,
            allowUnverifiedHardware: allowUnverifiedHardware,
            options: options,
            job: job
        )
    }

    private func loadJob() throws -> ScanJobDocument {
        do {
            return try ScanJobDocument.decode(readBoundedJobFile())
        } catch {
            try failBeforeConnection(
                ControlErrorPayload(
                    code: ControlErrorCode.invalidParams.rawValue,
                    message: "Could not validate job \"\(jobPath)\": \(jobValidationMessage(error))",
                    recoverable: false
                ),
                exitCode: .usage
            )
        }
    }

    private func readBoundedJobFile() throws -> Data {
        let descriptor = Darwin.open(jobPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= 1_048_576 else {
            throw ScanJobDocument.Invalid.document("Job input must be a regular file of at most 1 MiB.")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count <= 1_048_576 {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, 1_048_577 - data.count))
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw ScanJobDocument.Invalid.document("Job input must be a regular file of at most 1 MiB.")
    }

    private func requireExecutionConfirmations(_ job: ScanJobDocument) throws {
        guard job.confirmations.filmLoaded, filmLoaded else {
            try failBeforeConnection(
                ControlErrorPayload(
                    .confirmationRequired,
                    message: "Job execution requires confirmations.filmLoaded: true and --film-loaded.",
                    guidance: "Verify the named film is loaded, approve the document, and pass --film-loaded."
                ),
                exitCode: .confirmationRequired
            )
        }
        guard job.confirmations.motion, confirmMotion else {
            try failBeforeConnection(
                ControlErrorPayload(
                    .confirmationRequired,
                    message: "Job execution requires confirmations.motion: true and --confirm-motion.",
                    guidance: "Approve scanner motion in the document and pass --confirm-motion."
                ),
                exitCode: .confirmationRequired
            )
        }
    }

    private func runDryRun(_ job: ScanJobDocument) async throws {
        // `scan.preflight` is read-only in ControlHostDecision, so this cannot
        // auto-start a host even when the global preference is `.auto`.
        let client = try await CommandRunner.openConnection(command: "scan.preflight", options: options)
        let response = try await CommandRunner.request(
            command: "run",
            method: "scan.preflight",
            params: ControlScanPreflightParams(
                frames: job.frames,
                capture: job.capture,
                outputs: job.outputs,
                deviceId: job.deviceId
            ),
            options: options,
            client: client
        )
        guard case .result(let reportData) = response else {
            try await CommandRunner.finish(command: "run", options: options, client: client, response: response)
            return
        }
        let report: ScanPreflightReport
        let resultData: Data
        do {
            report = try JSONDecoder().decode(ScanPreflightReport.self, from: reportData)
            resultData = try JSONSerialization.data(withJSONObject: [
                "job": try JSONSerialization.jsonObject(with: job.normalizedJSON()),
                "preflight": try JSONSerialization.jsonObject(with: reportData),
            ])
        } catch {
            try await CommandRunner.fail(command: "run", options: options, client: client, error: error)
        }
        try await CommandRunner.finish(
            command: "run",
            options: options,
            client: client,
            response: .result(resultData)
        )
        if !report.ready {
            throw ExitCode(ControlCLIExitCode.engineOrGateError.rawValue)
        }
    }

    private func failBeforeConnection(_ payload: ControlErrorPayload, exitCode: ControlCLIExitCode) throws -> Never {
        print(try ControlCLIOutput.renderError(command: "run", payload: payload, human: options.human), terminator: "")
        throw ExitCode(exitCode.rawValue)
    }

    private func jobValidationMessage(_ error: Error) -> String {
        if case ScanJobDocument.Invalid.document(let message) = error { return message }
        return error.localizedDescription
    }
}

// The one shared path every subcommand's `run()` calls through: resolve
// the socket, open a connection, greet, send, render, exit (D-09/D-10).
// No command in `Commands/` constructs an `ExitCode` for a wire-originated
// refusal (T-02-15) or dials `ControlChannelClient` directly (T-02-23) --
// this file is the only place that does either. The exception, by design,
// is a `validate()` gate that decides its own fixed exit code before any
// connection exists (frames include/exclude's range shape, roll save's
// --confirm-motion) -- those print through `ControlCLIOutput` the same way
// this file does, but throw their own literal `ExitCode` since D-11's
// value for that refusal is fixed, not looked up from a wire code.

import ArgumentParser
import Foundation
import ScanStudioKit

enum CommandRunner {
    private static let clientName = "scanstudio-cli"

    /// `--socket` if given, otherwise the app's standard control socket
    /// path (D-15).
    static func socketPath(_ options: GlobalOptions) -> String {
        options.socketPath ?? ControlSocketPath.defaultPath()
    }

    /// Opens one connection for `command`. A thrown `ControlSocketError`
    /// becomes a ControlCLIErrorCode.hostUnreachable (HOST_UNREACHABLE)
    /// error body naming the socket path that was tried, with guidance to
    /// start ScanStudio or pass --socket, then exit 69 -- D-15's no-host-
    /// reachable case. Any other thrown error (including a refused
    /// `hello`) becomes an INTERNAL body and exit 70. Either failure is
    /// printed to stdout before throwing, so a script parses one stream.
    ///
    /// Callers that only need one request use `run`/`runWithoutParams`
    /// below; multi-request commands (frames include/exclude, settings/
    /// outputs set) call this directly and keep the connection open for
    /// several requests -- one connection per invocation, never one per
    /// request.
    static func openConnection(command: String, options: GlobalOptions) async throws -> ControlChannelClient {
        let path = socketPath(options)
        do {
            let resolution = try await ControlHostDecision.resolve(
                command: command, socketPath: path, preference: options.hostPreference
            )
            let client = try await ControlChannelClient.open(path: path, clientName: clientName)
            await client.setCLIEnvelopeContext(ControlCLIEnvelopeContext(
                mode: resolution.mode,
                hostStarted: resolution.hostStarted,
                hostPid: resolution.hostPid,
                logPath: resolution.logPath
            ))
            return client
        } catch let error as ControlHostDecisionError {
            try emitFailure(command: command, options: options, payload: error.payload)
            throw ExitCode(error.exitCode.rawValue)
        } catch let error as ControlSocketError {
            try emitFailure(command: command, options: options, payload: hostUnreachablePayload(path: path, error: error))
            throw ExitCode(ControlCLIExitCode.noHostReachable.rawValue)
        } catch {
            try emitFailure(command: command, options: options, payload: internalPayload(command: command, error: error))
            throw ExitCode(ControlCLIExitCode.internalError.rawValue)
        }
    }

    /// Issues one request on an already-open `client`. A typed refusal
    /// (`ControlErrorPayload`) comes back as a `.result`/`.failure` value,
    /// never thrown (D-14) -- only a transport-level throw (connection
    /// closed, malformed response, a cancellation) reaches this `catch`,
    /// mapped to the same INTERNAL/70 handling `openConnection` performs.
    static func request<Params: Encodable & Sendable>(
        command: String,
        method: String,
        params: Params,
        options: GlobalOptions,
        client: ControlChannelClient
    ) async throws -> ControlClientResponse {
        do {
            return try await client.request(method: method, params: params)
        } catch {
            let context = await client.cliEnvelopeContext
            await client.shutdown()
            try emitFailure(command: command, options: options, payload: internalPayload(command: command, error: error), context: context)
            throw ExitCode(ControlCLIExitCode.internalError.rawValue)
        }
    }

    /// For the channel's no-params commands.
    static func requestWithoutParams(
        command: String,
        method: String,
        options: GlobalOptions,
        client: ControlChannelClient
    ) async throws -> ControlClientResponse {
        try await request(command: command, method: method, params: EmptyParams(), options: options, client: client)
    }

    /// One request, one response, render, exit -- every read-only and
    /// single-mutation subcommand's `run()` body is this call plus params
    /// construction.
    static func run<Params: Encodable & Sendable>(
        command: String,
        method: String,
        params: Params,
        options: GlobalOptions
    ) async throws {
        let client = try await openConnection(command: command, options: options)
        let response = try await request(command: command, method: method, params: params, options: options, client: client)
        try await finish(command: command, options: options, client: client, response: response)
    }

    static func runWithoutParams(command: String, method: String, options: GlobalOptions) async throws {
        try await run(command: command, method: method, params: EmptyParams(), options: options)
    }

    /// Renders `response`, closes `client`. Success (`.result`) returns
    /// normally (exit 0). A typed failure (`.failure`) prints the payload
    /// then throws the D-10 exit code the shared table decides for its
    /// `code` -- never a value a command computed itself. Multi-request
    /// commands call this directly once they have their own final
    /// response to render (or a CLI-synthesized one, e.g. frames
    /// include/exclude's aggregate result).
    static func finish(
        command: String,
        options: GlobalOptions,
        client: ControlChannelClient,
        response: ControlClientResponse
    ) async throws {
        switch response {
        case .result(let data):
            let object = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            let context = await client.cliEnvelopeContext
            try emitResult(command: command, options: options, resultJSON: object, context: context)
            await client.shutdown()
        case .failure(let payload):
            let context = await client.cliEnvelopeContext
            try emitFailure(command: command, options: options, payload: payload, context: context)
            await client.shutdown()
            throw ExitCode(ControlCLIExitCode.forErrorCode(payload.code).rawValue)
        }
    }

    /// Renders `error` as this command's own INTERNAL failure, closes
    /// `client`, and throws the D-10 exit code -- exposed for a command
    /// that hits an unexpected condition after a request already
    /// succeeded (for example, `status --job`'s job.get response failing
    /// to decode). Never returns.
    static func fail(command: String, options: GlobalOptions, client: ControlChannelClient, error: Error) async throws -> Never {
        let context = await client.cliEnvelopeContext
        await client.shutdown()
        try emitFailure(command: command, options: options, payload: internalPayload(command: command, error: error), context: context)
        throw ExitCode(ControlCLIExitCode.internalError.rawValue)
    }

    private static func emitResult(command: String, options: GlobalOptions, resultJSON: [String: Any], context: ControlCLIEnvelopeContext = .unreached) throws {
        let text = try ControlCLIOutput.renderResult(command: command, resultJSON: resultJSON, human: options.human, context: context)
        print(text, terminator: "")
    }

    private static func emitFailure(command: String, options: GlobalOptions, payload: ControlErrorPayload, context: ControlCLIEnvelopeContext = .unreached) throws {
        let text = try ControlCLIOutput.renderError(command: command, payload: payload, human: options.human, context: context)
        print(text, terminator: "")
    }

    private static func hostUnreachablePayload(path: String, error: ControlSocketError) -> ControlErrorPayload {
        ControlErrorPayload(
            code: ControlCLIErrorCode.hostUnreachable.rawValue,
            message: "Could not reach a ScanStudio control socket at \(path): \(error.errorDescription ?? "connection failed").",
            recoverable: false,
            guidance: "Start ScanStudio, then retry, or pass --socket to point at a running app's control socket."
        )
    }

    private static func internalPayload(command: String, error: Error) -> ControlErrorPayload {
        ControlErrorPayload(
            code: ControlCLIErrorCode.internalCode.rawValue,
            message: "\"\(command)\" failed: \(String(describing: error))",
            recoverable: false
        )
    }
}

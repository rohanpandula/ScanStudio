import ArgumentParser
import Foundation
import ScanStudioKit

struct Wait: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for a session condition using the control event stream."
    )

    @OptionGroup var options: GlobalOptions

    @Option(name: .customLong("for"), help: "Condition: film-present, film-absent, idle, job-done, or registered.")
    var conditionName: String

    @Option(name: .customLong("timeout"), help: "Maximum wait in seconds (0–86400).")
    var timeout: Double = 60

    mutating func validate() throws {
        guard ControlWaitCondition(rawValue: conditionName) != nil else {
            throw ValidationError("--for must be one of: " + ControlWaitCondition.allCases.map(\.rawValue).joined(separator: ", "))
        }
        guard timeout.isFinite, (0...86_400).contains(timeout) else {
            throw ValidationError("--timeout must be between 0 and 86400 seconds")
        }
    }

    func run() async throws {
        guard let condition = ControlWaitCondition(rawValue: conditionName) else {
            throw ValidationError("--for must be one of: " + ControlWaitCondition.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let client = try await CommandRunner.openConnection(command: "wait", options: options)
        let response = try await CommandRunner.request(
            command: "wait",
            method: "events.subscribe",
            params: EmptyParams(),
            options: options,
            client: client
        )
        guard case .result(let data) = response else {
            try await CommandRunner.finish(command: "wait", options: options, client: client, response: response)
            return
        }
        let subscribed: ControlEventsSubscribeResult
        do {
            subscribed = try JSONDecoder().decode(ControlEventsSubscribeResult.self, from: data)
        } catch {
            try await CommandRunner.fail(command: "wait", options: options, client: client, error: error)
        }

        do {
            let status = try await ControlEventWaiter.wait(
                initial: subscribed.snapshot,
                events: await client.events(),
                condition: condition,
                timeout: timeout
            )
            let result = try ControlCLIOutput.renderResult(
                command: "wait",
                resultJSON: ["condition": condition.rawValue, "status": statusJSON(status)],
                human: options.human,
                context: await client.cliEnvelopeContext
            )
            print(result, terminator: "")
            await client.shutdown()
        } catch ControlEventWaitFailure.timeout {
            await client.shutdown()
            let payload = ControlErrorPayload(
                code: ControlCLIErrorCode.waitTimeout.rawValue,
                message: "wait timed out after \(timeout) seconds for \(condition.rawValue).",
                recoverable: false,
                guidance: "Increase --timeout or resolve the condition, then retry."
            )
            let result = try ControlCLIOutput.renderError(command: "wait", payload: payload, human: options.human)
            print(result, terminator: "")
            throw ExitCode(ControlCLIExitCode.waitTimedOut.rawValue)
        } catch ControlEventWaitFailure.hostExited {
            // ControlChannelClient adds the typed hostExited event on peer EOF.
            await client.shutdown()
            throw ExitCode(ControlCLIExitCode.hostExited.rawValue)
        } catch ControlEventWaitFailure.streamEnded {
            await client.shutdown()
            throw ExitCode(ControlCLIExitCode.hostExited.rawValue)
        }
    }

    private func statusJSON(_ status: ControlStatusResult) -> Any {
        guard let data = try? JSONEncoder().encode(status),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return object
    }

}

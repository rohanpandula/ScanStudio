import Darwin
import Foundation
import ScanStudioKit

enum HookRunner {
    private static let wrapper = #"""
    /bin/sh -c "$SCANSTUDIO_HOOK_COMMAND" & hook=$!
    (
      trap '' TERM
      sleep 10
      kill -TERM -$$ 2>/dev/null
      sleep 1
      kill -KILL -$$ 2>/dev/null
    ) & watchdog=$!
    wait "$hook"
    status=$?
    kill -KILL "$watchdog" 2>/dev/null
    (
      trap '' TERM
      kill -TERM -$$ 2>/dev/null
      sleep 1
      kill -KILL -$$ 2>/dev/null
    ) &
    exit "$status"
    """#

    /// Spawns one isolated shell process group and returns immediately. The
    /// child-owned watchdog survives this CLI and tears down that group after
    /// ten seconds; all stdio is `/dev/null`, so hook output is bounded at zero.
    static func launch(command: String, environment additions: [String: String]) throws {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            let flags = descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY
            guard posix_spawn_file_actions_addopen(&fileActions, descriptor, "/dev/null", flags, 0) == 0 else {
                throw POSIXError(.EIO)
            }
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw POSIXError(.EIO)
        }

        var environment = inheritedEnvironment()
        additions.forEach { environment[$0.key] = $0.value }
        environment["SCANSTUDIO_HOOK_COMMAND"] = command
        let arguments = ["/bin/sh", "-c", wrapper]
        let environmentEntries = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environmentEntries.map { strdup($0) } + [nil]
        defer {
            for pointer in argv { if let pointer { free(pointer) } }
            for pointer in envp { if let pointer { free(pointer) } }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, &argv, &envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        let childPID = pid
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) < 0, errno == EINTR {}
        }
    }

    private static func inheritedEnvironment() -> [String: String] {
        let source = ProcessInfo.processInfo.environment
        return ["HOME", "LANG", "LC_ALL", "PATH", "TMPDIR", "USER"].reduce(into: [:]) {
            if let value = source[$1] { $0[$1] = value }
        }
    }
}

final class HookDeliveryCoordinator: @unchecked Sendable {
    private let onFrame: String?
    private let onFail: String?
    private let marker: ActiveJobMarker
    private let context: ActiveJobMarker.Context

    init?(onFrame: String?, onFail: String?, marker: ActiveJobMarker?, context: ActiveJobMarker.Context?) {
        guard onFrame != nil || onFail != nil, let marker, let context else { return nil }
        self.onFrame = onFrame
        self.onFail = onFail
        self.marker = marker
        self.context = context
    }

    func observe(_ snapshot: ControlStatusResult) {
        guard let command = onFrame else { return }
        for receipt in snapshot.completedReceipts ?? [] where receipt.jobId == marker.jobId {
            let delivery = ActiveJobMarker.HookDelivery(
                key: "frame:\(marker.jobId):\(receipt.receiptKey)",
                kind: "frame",
                frameIndex: receipt.frameIndex,
                receiptKey: receipt.receiptKey,
                receiptPath: receipt.receiptPath,
                errorJSON: nil,
                recordedAt: ControlRunReceipt.isoTimestamp()
            )
            launchIfReserved(command: command, delivery: delivery)
        }
    }

    func observeFailure(_ result: ControlJobResult) {
        guard result.jobState == .failed, let command = onFail else { return }
        let errorObject: [String: Any] = [
            "jobId": marker.jobId,
            "jobState": "failed",
            "frameErrorCodes": result.frameErrorCodes,
            "frameErrorMessages": result.frameErrorMessages,
        ]
        guard JSONSerialization.isValidJSONObject(errorObject),
              let data = try? JSONSerialization.data(withJSONObject: errorObject, options: [.sortedKeys]),
              let errorJSON = String(data: data, encoding: .utf8) else { return }
        let delivery = ActiveJobMarker.HookDelivery(
            key: "fail:\(marker.jobId)",
            kind: "fail",
            frameIndex: nil,
            receiptKey: nil,
            receiptPath: nil,
            errorJSON: errorJSON,
            recordedAt: ControlRunReceipt.isoTimestamp()
        )
        launchIfReserved(command: command, delivery: delivery)
    }

    private func launchIfReserved(command: String, delivery: ActiveJobMarker.HookDelivery) {
        do {
            guard try ActiveJobMarker.reserveDelivery(delivery, for: marker, context: context) else { return }
            var environment = [
                "SCANSTUDIO_JOB_ID": marker.jobId,
                "SCANSTUDIO_CORRELATION_TOKEN": marker.correlationToken ?? "",
                "SCANSTUDIO_FRAME_INDEX": delivery.frameIndex.map(String.init) ?? "",
                "SCANSTUDIO_RECEIPT_KEY": delivery.receiptKey ?? "",
                "SCANSTUDIO_RECEIPT_PATH": delivery.receiptPath ?? "",
                "SCANSTUDIO_ERROR_JSON": delivery.errorJSON ?? "",
            ]
            environment["SCANSTUDIO_HOOK_KIND"] = delivery.kind
            try HookRunner.launch(command: command, environment: environment)
        } catch {
            FileHandle.standardError.write(Data("scanstudio-cli: hook launch recorded but failed: \(error)\n".utf8))
        }
    }
}

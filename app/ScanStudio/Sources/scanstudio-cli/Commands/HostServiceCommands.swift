import ArgumentParser
import Darwin
import Foundation
import ScanStudioKit

struct HostService: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "service", abstract: "Generate, install, or remove the managed headless LaunchAgent.")
    enum Action: String, ExpressibleByArgument { case generate, install, remove }
    @Argument var action: Action
    @OptionGroup var options: GlobalOptions
    @Option(help: "Absolute ScanStudio.app path. Required for generation and installation.") var bundle: String?
    @Option(name: .customLong("to"), help: "Create-only plist output for generate.") var destination: String?

    func run() async throws {
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let managed = home.appendingPathComponent("Library/LaunchAgents/\(HeadlessServicePlist.label).plist")
            let socket = CommandRunner.socketPath(options)
            let log = ControlHostPaths.defaultLogPath()
            let path: URL
            switch action {
            case .generate, .install:
                guard let bundle, bundle.hasPrefix("/") else { throw ValidationError("Provide an absolute --bundle path.") }
                if action == .generate {
                    guard let destination, destination.hasPrefix("/") else { throw ValidationError("generate requires an absolute --to path.") }
                    path = URL(fileURLWithPath: destination)
                } else {
                    guard destination == nil else { throw ValidationError("install uses only the managed LaunchAgents path.") }
                    path = managed
                }
                let data = try HeadlessServicePlist.data(bundle: URL(fileURLWithPath: bundle), socket: socket, log: log)
                if action == .install {
                    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try ControlSocketPath.prepareDirectory(for: socket)
                    try ControlSocketPath.prepareDirectory(for: log)
                }
                try data.write(to: path, options: [.withoutOverwriting])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                if action == .install { try launchctl(["bootstrap", "gui/\(getuid())", path.path]) }
            case .remove:
                guard bundle == nil, destination == nil else { throw ValidationError("remove accepts no bundle or destination override.") }
                path = managed
                let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
                      (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                      info.st_size <= 65_536,
                      let data = try handle.read(upToCount: 65_537),
                      let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      plist["Label"] as? String == HeadlessServicePlist.label,
                      plist["ScanStudioManagedServiceVersion"] as? Int == 1 else {
                    throw ValidationError("Refusing a plist not owned by the managed ScanStudio service.")
                }
                // A failed bootout leaves the plist intact so the caller can
                // inspect the service; never unload another label or retry.
                try launchctl(["bootout", "gui/\(getuid())/\(HeadlessServicePlist.label)"])
                try FileManager.default.removeItem(at: path)
            }
            print(try ControlCLIOutput.renderResult(command: "host.service", resultJSON: ["action": action.rawValue, "path": path.path, "label": HeadlessServicePlist.label], human: options.human), terminator: "")
        } catch {
            let payload = ControlErrorPayload(code: ControlErrorCode.invalidParams.rawValue, message: error.localizedDescription, recoverable: false, guidance: "Inspect the managed plist and launchctl state before retrying. Existing files are never overwritten.")
            print(try ControlCLIOutput.renderError(command: "host.service", payload: payload, human: options.human), terminator: "")
            throw ExitCode(ControlCLIExitCode.usage.rawValue)
        }
    }

    private func launchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ValidationError("launchctl exited \(process.terminationStatus); managed files were retained.") }
    }
}

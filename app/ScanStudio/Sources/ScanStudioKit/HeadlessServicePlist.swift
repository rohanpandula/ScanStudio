import Foundation

/// launchd supervises the existing resident host; socket exclusivity remains
/// in that host. No automatic restart loop can retry a refused hardware job.
public enum HeadlessServicePlist {
    public static let label = "com.scanstudio.headless"

    public static func data(bundle: URL, socket: String, log: String) throws -> Data {
        let cli = bundle.appendingPathComponent("Contents/MacOS/scanstudio-cli")
        guard bundle.path.hasPrefix("/"), bundle.pathExtension == "app",
              socket.hasPrefix("/"), log.hasPrefix("/"),
              ![bundle.path, socket, log].contains(where: { $0.contains("\0") }),
              FileManager.default.isExecutableFile(atPath: cli.path),
              FileManager.default.isExecutableFile(atPath: bundle.appendingPathComponent("Contents/MacOS/scanstudio-engine").path) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return try PropertyListSerialization.data(fromPropertyList: [
            "Label": label,
            "ScanStudioManagedServiceVersion": 1,
            "ProgramArguments": [cli.path, "host", "run", "--socket", socket, "--log", log],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Background",
            "Umask": 0o077,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ], format: .xml, options: 0)
    }
}

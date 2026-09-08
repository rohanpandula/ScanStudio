import ArgumentParser
import Darwin
import Foundation
import ScanStudioKit
import Security

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report installation, host, and cached scanner diagnostics without changing state."
    )

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let report = await DoctorCollector.collect(socketPath: CommandRunner.socketPath(options))
        let data = try JSONEncoder().encode(report)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let rendered = try ControlCLIOutput.renderResult(
            command: "doctor", resultJSON: object, human: options.human
        )
        print(rendered, terminator: "")
        if report.hasFailures {
            throw ExitCode(ControlCLIExitCode.engineOrGateError.rawValue)
        }
    }
}

private enum DoctorCollector {
    private struct Layout {
        let executable: URL
        let app: URL?

        init() {
            executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
                .resolvingSymlinksInPath()
            let macOS = executable.deletingLastPathComponent()
            let contents = macOS.deletingLastPathComponent()
            let candidate = contents.deletingLastPathComponent()
            app = macOS.lastPathComponent == "MacOS"
                && contents.lastPathComponent == "Contents"
                && candidate.pathExtension == "app" ? candidate : nil
        }
    }

    private struct HostSnapshot: Sendable {
        let hello: ControlHelloResult
        let status: ControlStatusResult?
        let inventory: ControlSessionInventoryResult?
    }

    private struct SignatureInspection {
        let valid: Bool
        let teamIdentifier: String?
        let error: String?
    }

    private struct DistributionIdentity {
        let version: String
        let sourceVersion: String
    }

    private struct USBScanner {
        let model: String
        let productID: Int
        let hubDepth: Int
    }

    static func collect(socketPath: String) async -> DoctorReport {
        let layout = Layout()
        let host = await hostSnapshot(socketPath: socketPath)
        let usb = usbScanners()
        var observations = installationObservations(layout: layout)
        observations += socketObservations(socketPath: socketPath, host: host)
        observations += hostObservations(host, packagedDriverVersion: packagedDriverVersion(layout))
        observations += scannerObservations(host: host, usb: usb)
        return DoctorReport(generatedAt: timestamp(), observations: observations)
    }

    private static func installationObservations(layout: Layout) -> [DoctorObservation] {
        guard let app = layout.app else {
            return [
                .warning(
                    id: "bundle.signature", value: nil,
                    detail: "This is a loose development CLI, so no containing ScanStudio.app signature exists.",
                    fix: "Run the CLI in place from a packaged ScanStudio.app to validate release signatures."
                ),
                .warning(
                    id: "bundle.version", value: nil,
                    detail: "This loose development CLI has no signed ScanStudio release stamp.",
                    fix: "Use the CLI embedded in a packaged ScanStudio.app."
                ),
                signatureObservation(id: "cli.signature", url: layout.executable, packaged: false),
                .warning(
                    id: "cli.version", value: nil,
                    detail: "The loose CLI has no signed bundle version authority.",
                    fix: "Use the CLI embedded in a packaged ScanStudio.app."
                ),
                .warning(
                    id: "bridge.bundleVersion", value: nil,
                    detail: "No packaged bridge distribution is associated with this loose CLI.",
                    fix: "Use the CLI embedded in a packaged ScanStudio.app."
                ),
                .warning(
                    id: "driver.bundleVersion", value: nil,
                    detail: "No packaged CoolscanPy distribution is associated with this loose CLI.",
                    fix: "Use the CLI embedded in a packaged ScanStudio.app."
                ),
                .warning(
                    id: "libusb.presence", value: nil,
                    detail: "No app-owned libusb location is associated with this loose CLI.",
                    fix: "Use the CLI embedded in a packaged ScanStudio.app."
                ),
            ]
        }

        let plist = infoPlist(app)
        let release = plist?["ScanStudioRelease"] as? String
        let shortVersion = plist?["CFBundleShortVersionString"] as? String
        let appSignature = inspectSignature(app, deep: true)
        let cliSignature = inspectSignature(layout.executable, deep: false)
        var observations: [DoctorObservation] = [
            signatureObservation(id: "bundle.signature", inspection: appSignature, packaged: true),
            versionObservation(id: "bundle.version", release: release, fallback: shortVersion),
            signatureObservation(id: "cli.signature", inspection: cliSignature, packaged: true),
            versionObservation(id: "cli.version", release: release, fallback: shortVersion),
        ]
        if let appTeam = appSignature.teamIdentifier,
           let cliTeam = cliSignature.teamIdentifier,
           appTeam != cliTeam {
            observations[2] = .invalid(
                id: "cli.signature", value: cliTeam,
                detail: "The CLI TeamIdentifier does not match the containing app (\(appTeam)).",
                fix: "Reinstall ScanStudio from one intact signed release."
            )
        }
        observations.append(distributionObservation(
            id: "bridge.bundleVersion", name: "scanstudio_bridge", app: app,
            sourceDirectory: "scanstudio-bridge"
        ))
        observations.append(distributionObservation(
            id: "driver.bundleVersion", name: "coolscanpy", app: app,
            sourceDirectory: "coolscanpy"
        ))
        let libusb = app.appendingPathComponent("Contents/Frameworks/coolscanpy/_native/libusb-1.0.dylib")
        observations.append(regularFileObservation(
            id: "libusb.presence", url: libusb,
            detail: "The app-owned libusb binary is present at its packaged path.",
            fix: "Reinstall ScanStudio so the bundled libusb binary is restored."
        ))
        return observations
    }

    private static func socketObservations(
        socketPath: String, host: HostSnapshot?
    ) -> [DoctorObservation] {
        let socketExists = pathState(socketPath)
        var observations: [DoctorObservation] = [
            socketPath.hasPrefix("/")
                ? .available(id: "socket.path", value: socketPath, detail: "The control socket path is absolute.")
                : .invalid(
                    id: "socket.path", value: socketPath,
                    detail: "The control socket path is not absolute.",
                    fix: "Pass an absolute path with --socket."
                ),
            host.map {
                .available(
                    id: "socket.liveness", value: "pid \($0.hello.hostPid)",
                    detail: "A ScanStudio \($0.hello.host.rawValue) host answered hello."
                )
            } ?? .warning(
                id: "socket.liveness", value: nil,
                detail: "No ScanStudio host answered this socket; doctor did not start one.",
                fix: "Start ScanStudio or a headless host if live checks are needed."
            ),
        ]
        switch (socketExists, host) {
        case (.missing, _), (.socket, .some):
            observations.append(.available(
                id: "socket.stalePath", value: socketExists.description,
                detail: host == nil ? "No abandoned socket path exists." : "The socket path is owned by the responding host."
            ))
        case (.socket, .none):
            observations.append(.warning(
                id: "socket.stalePath", value: socketPath,
                detail: "A socket file exists but no ScanStudio host answered it.",
                fix: "Confirm no host owns the path before removing the stale socket; doctor will not remove it."
            ))
        default:
            observations.append(.invalid(
                id: "socket.stalePath", value: socketPath,
                detail: "The configured socket path is occupied by an unsafe non-socket object.",
                fix: "Move the foreign object after confirming its ownership; doctor will not modify it."
            ))
        }

        let pidfile = ControlHostPaths.pidfilePath(forSocket: socketPath)
        do {
            let pid = try ControlHostPidfile.read(at: pidfile)
            if let pid, let host, pid == host.hello.hostPid {
                observations.append(.available(
                    id: "socket.pidfile", value: String(pid),
                    detail: "The owner-only pidfile matches the responding host."
                ))
            } else if let pid {
                observations.append(.warning(
                    id: "socket.pidfile", value: String(pid),
                    detail: "The pidfile does not identify a responding matching headless host.",
                    fix: "Confirm the recorded process is gone before removing the stale pidfile."
                ))
            } else {
                observations.append(.available(
                    id: "socket.pidfile", value: "absent",
                    detail: "No advisory headless-host pidfile is present."
                ))
            }
        } catch {
            observations.append(.invalid(
                id: "socket.pidfile", value: pidfile,
                detail: "The pidfile cannot be read safely: \(error).",
                fix: "Inspect the pidfile type, ownership, link count, and permissions manually."
            ))
        }
        observations.append(lockObservation(socketPath + ".lock"))
        return observations
    }

    private static func hostObservations(
        _ host: HostSnapshot?, packagedDriverVersion: String?
    ) -> [DoctorObservation] {
        guard let host else {
            return [
                unknown("engine.liveVersion", "Start ScanStudio to read its cached engine version."),
                unknown("bridge.liveVersion", "Start ScanStudio to read its cached bridge hello version."),
                unknown("driver.liveProvenance", "Start ScanStudio to inspect retained bridge provenance."),
                unknown("lamp.state", "Connect through a running host to expose its cached lamp state."),
            ]
        }
        var observations = [
            valueObservation(
                id: "engine.liveVersion", value: host.hello.engineVersion,
                unavailable: "The host has not cached an engine version.",
                fix: "Restart the host with its bundled engine and inspect the host log if hello still fails."
            ),
            valueObservation(
                id: "bridge.liveVersion", value: host.inventory?.bridgeVersion,
                unavailable: "The engine has no cached bridge hello version (simulator or legacy engine).",
                fix: "Use a hardware-enabled packaged host to expose a bridge identity."
            ),
        ]
        let provenance = driverProvenance(host.inventory)
        if let provenance {
            let rendered = [provenance.version, provenance.file, provenance.head].compactMap { $0 }.joined(separator: " | ")
            if let liveVersion = provenance.version,
               let packagedDriverVersion,
               liveVersion != packagedDriverVersion {
                observations.append(.invalid(
                    id: "driver.liveProvenance", value: rendered,
                    detail: "The running bridge loaded CoolscanPy \(liveVersion), but the bundle declares \(packagedDriverVersion).",
                    fix: "Quit the host and reinstall the intact packaged runtime."
                ))
            } else if provenance.version == nil {
                observations.append(.warning(
                    id: "driver.liveProvenance", value: rendered,
                    detail: "The retained bridge provenance record does not name a CoolscanPy version.",
                    fix: "Inspect the retained telemetry and restart from an intact packaged runtime."
                ))
            } else {
                observations.append(.available(
                    id: "driver.liveProvenance", value: rendered,
                    detail: "Retained bridge telemetry names the loaded CoolscanPy version and source."
                ))
            }
        } else {
            observations.append(unknown(
                "driver.liveProvenance",
                "No validated bridge.provenance record is available in retained telemetry."
            ))
        }
        if let lamp = host.status?.scanner?.lamp {
            observations.append(lamp == "stable"
                ? .available(id: "lamp.state", value: lamp, detail: "Cached scanner status reports a stable lamp.")
                : .warning(
                    id: "lamp.state", value: lamp,
                    detail: "Cached scanner status does not report a stable lamp.",
                    fix: "Wait for a stable cached status before an explicitly authorized scan."
                ))
        } else {
            observations.append(unknown(
                "lamp.state", "The host has no cached connected-scanner lamp state."
            ))
        }
        return observations
    }

    private static func scannerObservations(
        host: HostSnapshot?, usb: Result<[USBScanner], Error>
    ) -> [DoctorObservation] {
        let cached = (host?.hello.availableDevices ?? []).sorted { $0.deviceId < $1.deviceId }
        let cachedValue = cached.map { "\($0.deviceId) (\($0.model))" }.joined(separator: ", ")
        let enumeration: DoctorObservation = cached.isEmpty
            ? .warning(
                id: "scanner.enumeration", value: nil,
                detail: host == nil
                    ? "No host cache is available; doctor did not start or refresh one."
                    : "The host's cached scanner list is empty.",
                fix: "Check power and cabling, then explicitly rescan when desired."
            )
            : .available(
                id: "scanner.enumeration", value: cachedValue,
                detail: "Reported from the host's existing discovery cache without refreshing it."
            )
        let topology: DoctorObservation
        switch usb {
        case .failure(let error):
            topology = .warning(
                id: "usb.topology", value: nil,
                detail: "IORegistry USB topology was unavailable: \(error).",
                fix: "Run doctor on macOS with /usr/sbin/ioreg available."
            )
        case .success(let scanners) where scanners.isEmpty:
            topology = .warning(
                id: "usb.topology", value: nil,
                detail: "IORegistry contains no recognized Nikon Coolscan USB identity.",
                fix: "Check scanner power and cabling; no device was opened or refreshed."
            )
        case .success(let scanners):
            let scanners = scanners.sorted {
                ($0.productID, $0.hubDepth) < ($1.productID, $1.hubDepth)
            }
            let value = scanners.map {
                "\($0.model) 04b0:\(String(format: "%04x", $0.productID)) hubDepth=\($0.hubDepth)"
            }.joined(separator: ", ")
            let deepest = scanners.map(\.hubDepth).max() ?? 0
            topology = deepest == 0
                ? .available(
                    id: "usb.topology", value: value,
                    detail: "IORegistry reports the scanner without an intervening external hub."
                )
                : .warning(
                    id: "usb.topology", value: value,
                    detail: "IORegistry reports at least one intervening external USB hub.",
                    fix: "For capture reliability, attach the scanner directly when possible."
                )
        }
        return [enumeration, topology]
    }

    private static func hostSnapshot(socketPath: String) async -> HostSnapshot? {
        guard let client = try? await ControlChannelClient.open(
            path: socketPath, clientName: "scanstudio-cli doctor", helloTimeout: .seconds(2)
        ), let hello = await client.helloResult else { return nil }
        let snapshot = await withTaskGroup(of: HostSnapshot.self) { group in
            group.addTask {
                let status: ControlStatusResult? = await response(
                    client: client, method: "status", as: ControlStatusResult.self
                )
                guard !Task.isCancelled else {
                    return HostSnapshot(hello: hello, status: nil, inventory: nil)
                }
                let inventory: ControlSessionInventoryResult? = await response(
                    client: client, method: "session.inventory", as: ControlSessionInventoryResult.self
                )
                return HostSnapshot(hello: hello, status: status, inventory: inventory)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else {
                    return HostSnapshot(hello: hello, status: nil, inventory: nil)
                }
                await client.shutdown()
                return HostSnapshot(hello: hello, status: nil, inventory: nil)
            }
            let first = await group.next() ?? HostSnapshot(hello: hello, status: nil, inventory: nil)
            group.cancelAll()
            return first
        }
        await client.shutdown()
        return snapshot
    }

    private static func response<T: Decodable & Sendable>(
        client: ControlChannelClient, method: String, as type: T.Type
    ) async -> T? {
        guard let response = try? await client.request(method: method, params: EmptyParams()),
              case .result(let data) = response else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func signatureObservation(
        id: String, url: URL, packaged: Bool
    ) -> DoctorObservation {
        signatureObservation(id: id, inspection: inspectSignature(url, deep: false), packaged: packaged)
    }

    private static func signatureObservation(
        id: String, inspection: SignatureInspection, packaged: Bool
    ) -> DoctorObservation {
        guard inspection.valid else {
            return packaged
                ? .invalid(
                    id: id, value: inspection.error,
                    detail: "Code-signature validation failed.",
                    fix: "Reinstall ScanStudio from an intact signed release."
                )
                : .warning(
                    id: id, value: inspection.error,
                    detail: "The loose development binary has no valid release signature.",
                    fix: "Use the CLI embedded in a packaged ScanStudio.app."
                )
        }
        guard let team = inspection.teamIdentifier else {
            return .warning(
                id: id, value: "ad-hoc",
                detail: "The code signature is structurally valid but has no Developer ID TeamIdentifier.",
                fix: "Use a Developer ID signed and notarized release for production capture."
            )
        }
        return .available(
            id: id, value: team,
            detail: "Security.framework validated the code signature."
        )
    }

    private static func inspectSignature(_ url: URL, deep: Bool) -> SignatureInspection {
        var code: SecStaticCode?
        let create = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &code)
        guard create == errSecSuccess, let code else {
            return SignatureInspection(valid: false, teamIdentifier: nil, error: "OSStatus \(create)")
        }
        var rawFlags = kSecCSStrictValidate | kSecCSCheckAllArchitectures
        if deep { rawFlags |= kSecCSCheckNestedCode }
        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: rawFlags), nil)
        guard validity == errSecSuccess else {
            return SignatureInspection(valid: false, teamIdentifier: nil, error: "OSStatus \(validity)")
        }
        var rawInformation: CFDictionary?
        let copied = SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInformation
        )
        let information = rawInformation as? [String: Any]
        return SignatureInspection(
            valid: copied == errSecSuccess,
            teamIdentifier: information?[kSecCodeInfoTeamIdentifier as String] as? String,
            error: copied == errSecSuccess ? nil : "OSStatus \(copied)"
        )
    }

    private static func versionObservation(
        id: String, release: String?, fallback: String?
    ) -> DoctorObservation {
        if let release, !release.isEmpty {
            return .available(id: id, value: release, detail: "Read from the signed ScanStudioRelease stamp.")
        }
        return .warning(
            id: id, value: fallback,
            detail: "The package has no ScanStudioRelease stamp.",
            fix: "Use a release bundle produced by the signed packaging workflow."
        )
    }

    private static func distributionObservation(
        id: String, name: String, app: URL, sourceDirectory: String
    ) -> DoctorObservation {
        do {
            let identity = try distributionIdentity(name: name, app: app, sourceDirectory: sourceDirectory)
            guard identity.version == identity.sourceVersion else {
                return .invalid(
                    id: id, value: "metadata=\(identity.version), source=\(identity.sourceVersion)",
                    detail: "Packaged distribution metadata and corresponding source versions differ.",
                    fix: "Reinstall an intact ScanStudio package."
                )
            }
            return .available(
                id: id, value: identity.version,
                detail: "Distribution metadata matches the packaged corresponding-source pyproject."
            )
        } catch {
            return .invalid(
                id: id, value: nil, detail: "Packaged identity validation failed: \(error).",
                fix: "Reinstall ScanStudio so distribution metadata and corresponding source are present."
            )
        }
    }

    private static func distributionIdentity(
        name: String, app: URL, sourceDirectory: String
    ) throws -> DistributionIdentity {
        let sitePackages = app.appendingPathComponent("Contents/Resources/BridgeRuntime/site-packages")
        let prefix = name.replacingOccurrences(of: "-", with: "_") + "-"
        let directories = try FileManager.default.contentsOfDirectory(
            at: sitePackages, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ).filter { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return url.lastPathComponent.hasPrefix(prefix)
                && url.lastPathComponent.hasSuffix(".dist-info")
                && values?.isDirectory == true && values?.isSymbolicLink != true
        }
        guard directories.count == 1 else { throw DoctorReadError("expected one \(name) dist-info directory") }
        let metadata = try boundedText(directories[0].appendingPathComponent("METADATA"))
        guard metadata.split(separator: "\n").contains(where: { $0 == "Name: \(name.replacingOccurrences(of: "_", with: "-"))" }),
              let versionLine = metadata.split(separator: "\n").first(where: { $0.hasPrefix("Version: ") }) else {
            throw DoctorReadError("invalid \(name) METADATA")
        }
        let version = String(versionLine.dropFirst("Version: ".count))
        let pyproject = try boundedText(app.appendingPathComponent(
            "Contents/Resources/CorrespondingSource/\(sourceDirectory)/pyproject.toml"
        ))
        guard let sourceVersion = projectVersion(pyproject) else {
            throw DoctorReadError("missing [project] version in \(sourceDirectory)/pyproject.toml")
        }
        return DistributionIdentity(version: version, sourceVersion: sourceVersion)
    }

    private static func projectVersion(_ text: String) -> String? {
        var inProject = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inProject = line == "[project]"
                continue
            }
            guard inProject, line.hasPrefix("version = \"") && line.hasSuffix("\"") else { continue }
            return String(line.dropFirst("version = \"".count).dropLast())
        }
        return nil
    }

    private static func boundedText(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 1_048_576 else {
            throw DoctorReadError("unsafe or oversized file at \(url.path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func packagedDriverVersion(_ layout: Layout) -> String? {
        guard let app = layout.app else { return nil }
        return try? distributionIdentity(
            name: "coolscanpy", app: app, sourceDirectory: "coolscanpy"
        ).version
    }

    private static func driverProvenance(
        _ inventory: ControlSessionInventoryResult?
    ) -> (version: String?, file: String?, head: String?)? {
        guard let inventory,
              let entry = try? inventory.exportEntries().first(where: { $0.sourceKind == "bridgeTelemetry" })
        else { return nil }
        let data: Data
        do {
            guard let snapshot = try SessionEvidenceExporter.verifiedSnapshot(of: entry) else { return nil }
            data = snapshot
        } catch {
            return nil
        }
        for line in data.split(separator: 0x0A).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["method"] as? String == "bridge.provenance" else { continue }
            let version = object["version"] as? String
            let file = object["file"] as? String
            let head = object["head_sha"] as? String
            guard version != nil || file != nil || head != nil else { return nil }
            return (version, file, head)
        }
        return nil
    }

    private static func regularFileObservation(
        id: String, url: URL, detail: String, fix: String
    ) -> DoctorObservation {
        pathState(url.path) == .regular
            ? .available(id: id, value: url.path, detail: detail)
            : .invalid(id: id, value: url.path, detail: "The required packaged file is missing or unsafe.", fix: fix)
    }

    private static func lockObservation(_ path: String) -> DoctorObservation {
        var info = stat()
        if lstat(path, &info) != 0, errno == ENOENT {
            return .available(id: "socket.ownershipLock", value: "absent", detail: "No bind lock file is present.")
        }
        let safe = (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == geteuid() && info.st_nlink == 1
            && (info.st_mode & 0o077) == 0
        return safe
            ? .available(id: "socket.ownershipLock", value: path, detail: "The bind lock is a private owner-owned regular file.")
            : .invalid(
                id: "socket.ownershipLock", value: path,
                detail: "The bind lock path is not a private owner-owned single-link regular file.",
                fix: "Inspect the foreign or unsafe lock manually; doctor will not remove it."
            )
    }

    private enum PathState: Equatable, CustomStringConvertible {
        case missing, socket, regular, other
        var description: String {
            switch self { case .missing: "absent"; case .socket: "socket"; case .regular: "regular"; case .other: "other" }
        }
    }

    private static func pathState(_ path: String) -> PathState {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .missing : .other }
        switch info.st_mode & S_IFMT {
        case S_IFSOCK: return .socket
        case S_IFREG: return .regular
        default: return .other
        }
    }

    private static func infoPlist(_ app: URL) -> [String: Any]? {
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576 else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func usbScanners() -> Result<[USBScanner], Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-a", "-p", "IOUSB"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw DoctorReadError("ioreg exited \(process.terminationStatus)") }
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            var scanners: [USBScanner] = []
            walkUSB(plist, externalHubDepth: 0, scanners: &scanners)
            return .success(scanners)
        } catch {
            return .failure(error)
        }
    }

    private static func walkUSB(_ value: Any, externalHubDepth: Int, scanners: inout [USBScanner]) {
        if let values = value as? [Any] {
            for value in values { walkUSB(value, externalHubDepth: externalHubDepth, scanners: &scanners) }
            return
        }
        guard let node = value as? [String: Any] else { return }
        let name = [node["IORegistryEntryName"] as? String, node["IOObjectClass"] as? String]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let isExternalHub = name.contains("hub") && !name.contains("roothub") && !name.contains("root hub")
        let depth = externalHubDepth + (isExternalHub ? 1 : 0)
        if (node["idVendor"] as? NSNumber)?.intValue == 0x04b0,
           let product = (node["idProduct"] as? NSNumber)?.intValue,
           let model = [0x4000: "LS-40 ED", 0x4001: "LS-50 ED", 0x4002: "LS-5000 ED"][product] {
            scanners.append(USBScanner(model: model, productID: product, hubDepth: externalHubDepth))
        }
        if let children = node["IORegistryEntryChildren"] {
            walkUSB(children, externalHubDepth: depth, scanners: &scanners)
        }
    }

    private static func valueObservation(
        id: String, value: String?, unavailable: String, fix: String
    ) -> DoctorObservation {
        guard let value, !value.isEmpty else { return .warning(id: id, value: nil, detail: unavailable, fix: fix) }
        return .available(id: id, value: value, detail: "Reported from existing host state.")
    }

    private static func unknown(_ id: String, _ detail: String) -> DoctorObservation {
        .warning(id: id, value: nil, detail: detail, fix: "Collect this fact from a running packaged host when available.")
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private struct DoctorReadError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

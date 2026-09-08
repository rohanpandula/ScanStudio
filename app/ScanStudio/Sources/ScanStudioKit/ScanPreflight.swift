import Foundation
import Darwin

public struct ControlScanPreflightParams: Codable, Equatable, Sendable {
    public let frames: [Int]?
    public let resume: Bool?
    public let capture: CaptureRecipe?
    public let outputs: OutputRecipe?
    public let deviceId: String?
    public init(frames: [Int]? = nil, resume: Bool = false, capture: CaptureRecipe? = nil, outputs: OutputRecipe? = nil, deviceId: String? = nil) {
        self.frames = frames
        self.resume = resume
        self.capture = capture
        self.outputs = outputs
        self.deviceId = deviceId
    }
}

public struct ScanPreflightReport: Codable, Equatable, Sendable {
    public struct Check: Codable, Equatable, Sendable {
        public let code: String
        public let passed: Bool
        public let guidance: String
    }
    public let ready: Bool
    public let frames: [Int]
    public let estimatedBytes: UInt64
    public let checks: [Check]

    /// Cached readiness plus observational filesystem checks. Admission still
    /// owns the final held-directory and hardware checks after this snapshot.
    public static func evaluate(
        status: ControlStatusResult, frames: [Int],
        readiness: ScanReadinessPolicy.Decision,
        capture: CaptureRecipe, outputs: OutputRecipe,
        expectedDeviceId: String? = nil
    ) -> Self {
        var checks: [Check] = []
        func check(_ code: String, _ passed: Bool, _ guidance: String) {
            checks.append(Check(code: code, passed: passed, guidance: guidance))
        }
        check(
            "DEVICE_MATCH",
            expectedDeviceId == nil || status.device?.deviceId == expectedDeviceId,
            "Connect the exact scanner named by the job before relying on this preflight."
        )
        check("FRAMES_REQUIRED", !frames.isEmpty, "Select at least one frame.")
        let filmLoaded = status.device?.kind == "simulated"
            ? status.scanner?.mediaLoaded == true : status.scanner?.filmPresent == true
        check("FILM_REQUIRED", filmLoaded, "Load film and explicitly refresh scanner status before scanning.")
        check("REGISTRATION_REQUIRED", status.previewComplete && !status.refeedRequired, "Acquire and review a preview of the currently loaded film.")
        check("MOTION_NOT_READY", status.motionAllowed, status.motionGuidance ?? "Resolve the scanner's motion readiness before scanning.")
        check("SCAN_NOT_READY", readiness.isReady, readiness.reason ?? "Scan readiness passed.")
        check("CONTROLLER_BUSY", status.mutatingOperationInFlight == nil, "Wait for the admitted operation to finish.")

        let metadataDestinations = [
            ("archive", outputs.archive.enabled, outputs.archive.destination),
            ("positive", outputs.positive.enabled, outputs.positive.destination),
            ("preview", outputs.preview.enabled, outputs.preview.destination),
        ]
        // Match the engine's admission rule early enough for --dry-run to be
        // useful. This is an observational lexical check only; the engine's
        // held directory authorities remain the final security boundary.
        if let projectDirectory = status.projectDirectory {
            let root = URL(fileURLWithPath: projectDirectory).standardizedFileURL.path
            let rootPrefix = root == "/" ? "/" : root + "/"
            for (role, enabled, destination) in metadataDestinations where enabled {
                let path = URL(fileURLWithPath: destination).standardizedFileURL.path
                let withinProject = path == root || path.hasPrefix(rootPrefix)
                check(
                    "DESTINATION_WITHIN_PROJECT",
                    withinProject,
                    withinProject
                        ? destination
                        : "\(role) destination must be beneath the active project's metadata-safe output root: \(destination)"
                )
            }
        }
        let destinations = metadataDestinations.map { ($0.1, $0.2) }
            + [(outputs.rawExport.enabled, outputs.rawExport.destination)]
        let writableDestinations = destinations.filter { $0.0 }.map { $0.1 }
        // ponytail: conservative full-frame 35mm estimate, including scratch
        // space; use measured per-format estimates if this rejects useful runs.
        let scale = Double(capture.resolutionDpi) / 4000
        let bytes = Double(max(1, frames.count)) * max(1, scale * scale) * 268_435_456
        let bounded = bytes.isFinite && bytes < Double(UInt64.max) && capture.resolutionDpi > 0
        let perDestination = bounded ? UInt64(bytes) : UInt64.max
        var requiredByVolume: [UInt64: (required: UInt64, available: UInt64)] = [:]
        var total: UInt64 = 0
        var allocations: [String: UInt64] = [:]
        for destination in writableDestinations { allocations[destination, default: 0] += 1 }
        if let project = status.projectDirectory { allocations[project, default: 0] += 2 }
        for path in allocations.keys.sorted() {
            let allocation = perDestination.multipliedReportingOverflow(by: allocations[path]!)
            let required = allocation.overflow ? UInt64.max : allocation.partialValue
            do {
                guard path.hasPrefix("/") else { throw CocoaError(.fileReadInvalidFileName) }
                var directory = URL(fileURLWithPath: path).standardizedFileURL
                var isDirectory: ObjCBool = false
                while !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), directory.path != "/" {
                    directory.deleteLastPathComponent()
                }
                guard isDirectory.boolValue, access(directory.path, W_OK | X_OK) == 0 else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
                guard let available = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value else {
                    throw CocoaError(.fileReadUnknown)
                }
                var state = stat()
                guard stat(directory.path, &state) == 0 else { throw CocoaError(.fileReadUnknown) }
                let volume = UInt64(UInt32(bitPattern: state.st_dev))
                let previous = requiredByVolume[volume]?.required ?? 0
                let sum = previous.addingReportingOverflow(required)
                requiredByVolume[volume] = (sum.overflow ? UInt64.max : sum.partialValue, available)
                let aggregate = total.addingReportingOverflow(required)
                total = aggregate.overflow ? UInt64.max : aggregate.partialValue
                check("DESTINATION_WRITABLE", true, path)
            } catch {
                check("DESTINATION_NOT_WRITABLE", false, "Choose a writable output directory: \(path) (\(error.localizedDescription))")
            }
        }
        for volume in requiredByVolume.keys.sorted() {
            let value = requiredByVolume[volume]!
            check("INSUFFICIENT_SPACE", bounded && value.available >= value.required,
                  "Volume \(volume) has \(value.available) free bytes; conservatively requires \(value.required).")
        }
        return Self(ready: checks.allSatisfy(\.passed), frames: frames, estimatedBytes: total, checks: checks)
    }
}

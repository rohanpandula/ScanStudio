import CryptoKit
import Foundation

public struct RollHTMLReportResult: Codable, Equatable, Sendable {
    public let path: String
    public let frameCount: Int
    public let receiptCount: Int
    public let embeddedThumbnailCount: Int

    public init(path: String, frameCount: Int, receiptCount: Int, embeddedThumbnailCount: Int) {
        self.path = path
        self.frameCount = frameCount
        self.receiptCount = receiptCount
        self.embeddedThumbnailCount = embeddedThumbnailCount
    }
}

public enum RollHTMLReportError: Error, LocalizedError, Equatable, Sendable {
    case projectDirectoryMissing(String)
    case manifestUnreadable(String)
    case invalidDestination(String)
    case destinationExists(String)
    case invalidBinding(String)
    case artifactChanged(String)

    public var errorDescription: String? {
        switch self {
        case .projectDirectoryMissing(let path): "Roll directory is missing: \(path)"
        case .manifestUnreadable(let path): "Could not read the roll manifest: \(path)"
        case .invalidDestination(let path): "Report destination is invalid: \(path)"
        case .destinationExists(let path): "Report destination already exists: \(path)"
        case .invalidBinding(let detail): "Roll report artifact binding is invalid: \(detail)"
        case .artifactChanged(let detail): "A retained roll artifact changed: \(detail)"
        }
    }
}

/// Creates a self-contained, read-only contact sheet from one retained roll.
/// Source files are admitted only through engine-minted bindings and the
/// existing held-root/hash verifier. No recipe destination or receipt path is
/// used as file authority.
public enum RollHTMLReport {
    private static let maximumEmbeddedThumbnailBytes = 32 * 1024 * 1024

    public static func write(
        projectDirectory: URL,
        destination: URL? = nil
    ) throws -> RollHTMLReportResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RollHTMLReportError.projectDirectoryMissing(projectDirectory.path)
        }
        guard let project = ProjectSnapshotReader.read(projectDirectory.appendingPathComponent("manifest.json")) else {
            throw RollHTMLReportError.manifestUnreadable(projectDirectory.path)
        }
        let data = try render(project: project, projectDirectory: projectDirectory)
        let output = destination ?? projectDirectory.appendingPathComponent("report.html")
        guard output.path.hasPrefix("/"), !output.path.contains("\0") else {
            throw RollHTMLReportError.invalidDestination(output.path)
        }
        let parent = output.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw RollHTMLReportError.invalidDestination(output.path)
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw RollHTMLReportError.destinationExists(output.path)
        }
        do {
            try data.write(to: output, options: [.withoutOverwriting])
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw RollHTMLReportError.destinationExists(output.path)
        }
        let receipts = project.frames.reduce(0) { $0 + $1.receipts.count }
        let embedded = project.frames.flatMap(\.receipts).filter { receipt in
            receipt.outputs?.metadataBindings?.preview != nil
        }.count
        return RollHTMLReportResult(
            path: output.path,
            frameCount: project.frames.count,
            receiptCount: receipts,
            embeddedThumbnailCount: embedded
        )
    }

    public static func render(project: ScanProject, projectDirectory: URL) throws -> Data {
        var body: [String] = []
        body.append("<!doctype html><html><head><meta charset=\"utf-8\">")
        body.append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
        body.append("<title>\(escape(project.name))</title><style>\(style)</style></head><body>")
        body.append("<header><h1>\(escape(project.name))</h1><p>\(escape(project.filmProcess.rawValue)) · \(project.frameCount) frames · created \(escape(project.createdAt))</p></header>")
        body.append("<main class=\"frames\">")

        for frame in project.frames.sorted(by: { $0.index < $1.index }) {
            body.append("<article class=\"frame\"><h2>Frame \(frame.index)</h2>")
            let excluded = frame.excluded ? "yes" : "no"
            body.append("<p class=\"flags\">Excluded: \(excluded) · Review flags: Unknown (preview review evidence is not persisted)</p>")
            if let alignment = frame.alignment {
                let approval = alignment.approved ? "approved" : "draft"
                body.append("<p class=\"flags\">Alignment: \(approval), offset \(alignment.offsetRows) rows</p>")
            }
            if frame.receipts.isEmpty {
                body.append("<p class=\"unknown\">No retained receipt.</p></article>")
                continue
            }
            var embeddedThumbnailBytes = 0
            for receipt in frame.receipts {
                body.append(try render(
                    receipt: receipt,
                    projectDirectory: projectDirectory,
                    embeddedThumbnailBytes: &embeddedThumbnailBytes
                ))
            }
            body.append("</article>")
        }
        body.append("</main></body></html>")
        return Data(body.joined().utf8)
    }

    private static func render(
        receipt: ScanReceipt,
        projectDirectory: URL,
        embeddedThumbnailBytes: inout Int
    ) throws -> String {
        let receiptHash = try hash(receipt)
        let pass = escape(receipt.passToken ?? "default")
        var html = "<section class=\"receipt\"><h3>Pass \(pass)</h3>"
        html += "<p>Started: \(escape(receipt.startedAt)) · Duration: \(receipt.durationMs) ms · Normalized receipt hash: <code>\(receiptHash)</code></p>"
        if let telemetry = receipt.hardwareTelemetry {
            let exposure = telemetry.exposure
            html += "<p>Exposure RGB: \(exposure.redExposureUs) / \(exposure.greenExposureUs) / \(exposure.blueExposureUs) µs</p>"
        } else {
            html += "<p>Exposure: Unknown</p>"
        }

        var outputs: [(label: String, binding: WrittenFileBinding)] = []
        if let bindings = receipt.outputs?.metadataBindings {
            if let binding = bindings.archive { outputs.append(("Archive", binding)) }
            if let binding = bindings.positive { outputs.append(("Positive", binding)) }
            if let binding = bindings.preview { outputs.append(("Preview", binding)) }
        }
        if let bindings = receipt.outputs?.captureBindings {
            if let binding = bindings.rawNegative { outputs.append(("Raw negative", binding)) }
            if let binding = bindings.rawNegativeIr { outputs.append(("Infrared", binding)) }
            if let binding = bindings.meter { outputs.append(("Meter", binding)) }
        }

        if outputs.isEmpty {
            html += "<p class=\"unknown\">Verified output bindings unavailable.</p>"
        } else {
            html += "<ul class=\"outputs\">"
            for output in outputs {
                let data = try verifiedData(
                    output.binding,
                    label: output.label,
                    projectDirectory: projectDirectory,
                    embeddedThumbnailBytes: &embeddedThumbnailBytes
                )
                html += "<li>\(escape(output.label)): <code>\(escape(output.binding.relativePath))</code> · <code>\(escape(output.binding.sha256))</code></li>"
                if output.label == "Preview", let data {
                    html += "<img class=\"thumbnail\" alt=\"Frame \(receipt.frameIndex) preview\" src=\"data:\(mime(for: output.binding.relativePath));base64,\(data.base64EncodedString())\">"
                }
            }
            html += "</ul>"
        }
        return html + "</section>"
    }

    private static func verifiedData(
        _ binding: WrittenFileBinding,
        label: String,
        projectDirectory: URL,
        embeddedThumbnailBytes: inout Int
    ) throws -> Data? {
        let relative = binding.relativePath
        guard !relative.isEmpty, !relative.contains("\0"), !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else {
            throw RollHTMLReportError.invalidBinding("\(label) path \(relative)")
        }
        let source = projectDirectory.appendingPathComponent(relative)
        let entry = SessionEvidenceInventoryEntry(
            entryName: "roll-report-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))",
            sourceKind: "rollReport",
            source: .file(source, allowedRoot: projectDirectory),
            expectedSha256: binding.sha256
        )
        do {
            if label == "Preview" {
                guard let data = try SessionEvidenceExporter.verifiedSnapshot(of: entry),
                      data.count == binding.byteLength else {
                    throw RollHTMLReportError.artifactChanged("\(label) byte length")
                }
                guard data.count <= Self.maximumEmbeddedThumbnailBytes,
                      embeddedThumbnailBytes <= Self.maximumEmbeddedThumbnailBytes - data.count else {
                    throw RollHTMLReportError.artifactChanged("embedded thumbnails exceed report limit")
                }
                embeddedThumbnailBytes += data.count
                return data
            }

            guard let digest = try SessionEvidenceExporter.verifiedDigest(of: entry),
                  digest.byteLength == binding.byteLength else {
                throw RollHTMLReportError.artifactChanged("\(label) byte length")
            }
            return nil
        } catch let error as RollHTMLReportError {
            throw error
        } catch {
            throw RollHTMLReportError.artifactChanged("\(label): \(error.localizedDescription)")
        }
    }

    private static func hash(_ receipt: ScanReceipt) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func mime(for path: String) -> String {
        switch path.lowercased().split(separator: ".").last.map(String.init) {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "tif", "tiff": "image/tiff"
        default: "application/octet-stream"
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let style = "body{font:14px -apple-system,sans-serif;color:#222;background:#f5f3ef;margin:0;padding:24px}header{max-width:1100px;margin:auto}.frames{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px;max-width:1100px;margin:auto}.frame{background:white;border:1px solid #ddd;padding:14px}.receipt{border-top:1px solid #eee;margin-top:12px;padding-top:8px}.flags,.unknown{color:#666;font-size:12px}.outputs{padding-left:18px;font-size:11px;overflow-wrap:anywhere}.thumbnail{display:block;max-width:100%;max-height:260px;object-fit:contain;margin-top:10px}code{font-size:10px;overflow-wrap:anywhere}"
}

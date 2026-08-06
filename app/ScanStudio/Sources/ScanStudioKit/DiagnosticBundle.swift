import Foundation

/// A minimal, dependency-free ZIP writer using the uncompressed ("stored")
/// method only. "Save Diagnostic Bundle..." (T-ERR-04) favors a small,
/// easily-audited implementation over a compression dependency: the JSONL
/// log and report text are already small, and a preview raster is already a
/// compressed image format (PNG/TIFF), so stored-only costs little.
public enum StoredZipWriter {
    public struct Entry: Equatable {
        public let name: String
        public let data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    /// A fixed, valid DOS date/time (1980-01-01, the DOS epoch) so archive
    /// bytes are deterministic and never depend on wall-clock time -- the
    /// bundle's own report.txt already timestamps the export.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x21
    // General-purpose bit 11: filenames/comments are UTF-8, per the ZIP
    // appendix D "language encoding flag" -- entry names below are never
    // guaranteed ASCII (e.g. a preview file's original extension).
    private static let utf8NameFlag: UInt16 = 0x0800

    public static func write(_ entries: [Entry]) -> Data {
        var output = Data()
        var centralDirectory = Data()
        var recordCount: UInt16 = 0

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let localHeaderOffset = UInt32(output.count)

            var localHeader = Data()
            appendUInt32LE(0x0403_4b50, to: &localHeader)
            appendUInt16LE(20, to: &localHeader)
            appendUInt16LE(utf8NameFlag, to: &localHeader)
            appendUInt16LE(0, to: &localHeader)
            appendUInt16LE(dosTime, to: &localHeader)
            appendUInt16LE(dosDate, to: &localHeader)
            appendUInt32LE(crc, to: &localHeader)
            appendUInt32LE(size, to: &localHeader)
            appendUInt32LE(size, to: &localHeader)
            appendUInt16LE(UInt16(nameBytes.count), to: &localHeader)
            appendUInt16LE(0, to: &localHeader)
            localHeader.append(contentsOf: nameBytes)

            output.append(localHeader)
            output.append(entry.data)

            var centralEntry = Data()
            appendUInt32LE(0x0201_4b50, to: &centralEntry)
            appendUInt16LE(20, to: &centralEntry)
            appendUInt16LE(20, to: &centralEntry)
            appendUInt16LE(utf8NameFlag, to: &centralEntry)
            appendUInt16LE(0, to: &centralEntry)
            appendUInt16LE(dosTime, to: &centralEntry)
            appendUInt16LE(dosDate, to: &centralEntry)
            appendUInt32LE(crc, to: &centralEntry)
            appendUInt32LE(size, to: &centralEntry)
            appendUInt32LE(size, to: &centralEntry)
            appendUInt16LE(UInt16(nameBytes.count), to: &centralEntry)
            appendUInt16LE(0, to: &centralEntry)
            appendUInt16LE(0, to: &centralEntry)
            appendUInt16LE(0, to: &centralEntry)
            appendUInt16LE(0, to: &centralEntry)
            appendUInt32LE(0, to: &centralEntry)
            appendUInt32LE(localHeaderOffset, to: &centralEntry)
            centralEntry.append(contentsOf: nameBytes)

            centralDirectory.append(centralEntry)
            recordCount += 1
        }

        let centralDirectoryOffset = UInt32(output.count)
        output.append(centralDirectory)

        var eocd = Data()
        appendUInt32LE(0x0605_4b50, to: &eocd)
        appendUInt16LE(0, to: &eocd)
        appendUInt16LE(0, to: &eocd)
        appendUInt16LE(recordCount, to: &eocd)
        appendUInt16LE(recordCount, to: &eocd)
        appendUInt32LE(UInt32(centralDirectory.count), to: &eocd)
        appendUInt32LE(centralDirectoryOffset, to: &eocd)
        appendUInt16LE(0, to: &eocd)
        output.append(eocd)

        return output
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static let crcTable: [UInt32] = {
        (0...255).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1 != 0) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Assembles "Save Diagnostic Bundle..."'s contents (T-ERR-04) from
/// already-in-memory data -- no filesystem access here, so the exact
/// contents (including the honest manifest note when the raster is missing)
/// are unit-testable with plain values, no real files or fake filesystem
/// needed for this half of the pipeline.
public enum DiagnosticBundleBuilder {
    public struct PreviewRaster: Equatable {
        public let filename: String
        public let data: Data

        public init(filename: String, data: Data) {
            self.filename = filename
            self.data = data
        }
    }

    /// - Parameters:
    ///   - diagnosticsJSONL: the current session's diagnostics log, one JSON
    ///     object per line (`SessionDiagnosticTimeline`'s durable format).
    ///   - reportText: the generated error report (`ErrorPresentation
    ///     .technicalDetails`) at the moment the bundle was requested.
    ///   - previewRaster: the roll preview raster file, when the session had
    ///     one and the frontend could locate it from already-decoded
    ///     `Thumbnail.imagePath` state -- never a new engine round trip.
    ///   - unavailableRasterReason: when `previewRaster` is `nil`, the
    ///     specific, honest reason recorded in `manifest.txt` instead of
    ///     silently omitting the raster with no explanation.
    public static func makeEntries(
        diagnosticsJSONL: Data,
        reportText: String,
        previewRaster: PreviewRaster?,
        unavailableRasterReason: String?
    ) -> [StoredZipWriter.Entry] {
        var manifestLines = [
            "ScanStudio diagnostic bundle",
            "",
            "diagnostics.jsonl: this session's diagnostic events, one JSON object per line",
            "report.txt: the generated error report at the time of export",
        ]
        var entries = [
            StoredZipWriter.Entry(name: "diagnostics.jsonl", data: diagnosticsJSONL),
            StoredZipWriter.Entry(name: "report.txt", data: Data(reportText.utf8)),
        ]
        if let previewRaster {
            manifestLines.append("\(previewRaster.filename): the roll preview raster")
            entries.append(StoredZipWriter.Entry(name: previewRaster.filename, data: previewRaster.data))
        } else {
            let reason = unavailableRasterReason ?? "no roll preview in this session"
            manifestLines.append("raster: not available in this build (\(reason))")
        }
        entries.append(
            StoredZipWriter.Entry(
                name: "manifest.txt",
                data: Data(manifestLines.joined(separator: "\n").utf8)
            )
        )
        return entries
    }
}

/// Resolves the diagnostic bundle's preview raster from state the frontend
/// already holds -- `Thumbnail.imagePath`, exactly what the contact sheet
/// already reads to render preview tiles -- never a new bridge/engine wire
/// method. `readFile` is injectable so this is testable against a fake
/// filesystem (a plain `[String: Data]` lookup) with zero real disk I/O.
public enum DiagnosticBundleRasterPolicy {
    public static func resolve(
        thumbnails: [Int: Thumbnail],
        readFile: (String) -> Data?
    ) -> (raster: DiagnosticBundleBuilder.PreviewRaster?, unavailableReason: String?) {
        guard !thumbnails.isEmpty else {
            return (nil, "no roll preview in this session")
        }
        guard
            let lowestIndex = thumbnails.keys.sorted().first,
            let imagePath = thumbnails[lowestIndex]?.imagePath,
            !imagePath.isEmpty
        else {
            return (nil, "the roll preview has no locally-known image path")
        }
        guard let data = readFile(imagePath) else {
            return (nil, "the roll preview image file is missing or unreadable")
        }
        let extensionName = URL(fileURLWithPath: imagePath).pathExtension
        let filename = extensionName.isEmpty ? "preview" : "preview.\(extensionName)"
        return (DiagnosticBundleBuilder.PreviewRaster(filename: filename, data: data), nil)
    }
}

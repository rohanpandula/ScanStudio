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

/// Consent for one exact preview tile. Consent is bound to the frame and
/// source path visible when the operator opts in; a replacement preview or
/// path change invalidates it before any film bytes are read.
public struct DiagnosticPreviewConsent: Equatable, Sendable {
    public let frameIndex: Int
    public let sourcePath: String
    public let filename: String

    public init(frameIndex: Int, sourcePath: String, filename: String) {
        self.frameIndex = frameIndex
        self.sourcePath = sourcePath
        self.filename = filename
    }
}

/// Assembles a share-facing archive from already-held state. The local
/// technical-details view remains complete; this boundary applies a second,
/// archive-specific redaction pass to every text route.
public enum DiagnosticBundleBuilder {
    public struct PreviewRaster: Equatable, Sendable {
        public let filename: String
        public let data: Data

        public init(filename: String, data: Data) {
            self.filename = filename
            self.data = data
        }
    }

    public enum PreviewContent: Equatable, Sendable {
        case included(consent: DiagnosticPreviewConsent, raster: PreviewRaster)
        case excludedByPrivacyDefault(candidate: DiagnosticPreviewConsent?)
        case unavailable(reason: String)
    }

    public enum EvidenceContent: Equatable, Sendable {
        case included(DiagnosticEvidenceArtifact)
        case unavailable(reason: String)
    }

    public static func makeEntries(
        diagnosticsJSONL: Data,
        reportText: String,
        redactionContext: ErrorPresentationContext,
        preview: PreviewContent,
        evidence: EvidenceContent
    ) -> [StoredZipWriter.Entry] {
        var manifestLines = [
            "ScanStudio diagnostic bundle",
            "",
            "diagnostics.jsonl: share-redacted session events, one JSON object per line",
            "report.txt: share-redacted error report at the time of export",
        ]
        var entries = [
            StoredZipWriter.Entry(
                name: "diagnostics.jsonl",
                data: sanitizedDiagnosticsJSONL(
                    diagnosticsJSONL,
                    context: redactionContext
                )
            ),
            StoredZipWriter.Entry(
                name: "report.txt",
                data: Data(ErrorPresentationPolicy.redactShareFacingText(
                    reportText,
                    context: redactionContext
                ).utf8)
            ),
        ]

        switch preview {
        case .included(let consent, let raster):
            let filename = canonicalPreviewFilename(raster.filename)
            manifestLines.append(
                "\(filename): explicitly included film content from frame \(consent.frameIndex)"
            )
            entries.append(StoredZipWriter.Entry(name: filename, data: raster.data))
        case .excludedByPrivacyDefault(let candidate):
            if let candidate {
                manifestLines.append(
                    "film preview: excluded by privacy default (available frame: \(candidate.frameIndex))"
                )
            } else {
                manifestLines.append(
                    "film preview: excluded by privacy default (no locally-known candidate)"
                )
            }
        case .unavailable(let reason):
            manifestLines.append(
                "film preview: unavailable (\(safeReason(reason, context: redactionContext)))"
            )
        }

        switch evidence {
        case .included(let artifact):
            if let data = encodedShareSafeEvidence(
                artifact,
                context: redactionContext
            ) {
                entries.append(StoredZipWriter.Entry(
                    name: "evidence-v1.json",
                    data: data
                ))
                manifestLines.append(
                    "bounded evidence: included \(artifact.evidenceId) as evidence-v1.json"
                )
            } else {
                manifestLines.append(
                    "bounded evidence: unavailable (the supplied witness failed strict validation or share-safety checks)"
                )
            }
        case .unavailable(let reason):
            manifestLines.append(
                "bounded evidence: unavailable (\(safeReason(reason, context: redactionContext)))"
            )
        }

        entries.append(StoredZipWriter.Entry(
            name: "manifest.txt",
            data: Data(manifestLines.joined(separator: "\n").utf8)
        ))
        return entries
    }

    private static func sanitizedDiagnosticsJSONL(
        _ data: Data,
        context: ErrorPresentationContext
    ) -> Data {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var output = Data()

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let entry = try? decoder.decode(
                SessionDiagnosticEntry.self,
                from: Data(line)
            ) else {
                // Unknown JSON cannot be proven share-safe, so fail closed.
                continue
            }
            let sanitized = SessionDiagnosticEntry(
                timestamp: ErrorPresentationPolicy.redactShareFacingText(
                    entry.timestamp,
                    context: context
                ),
                sessionId: "redacted",
                event: ErrorPresentationPolicy.redactShareFacingText(
                    entry.event,
                    context: context
                ),
                fields: sanitizedObject(entry.fields, context: context)
            )
            guard let encoded = try? encoder.encode(sanitized) else { continue }
            output.append(encoded)
            output.append(0x0A)
        }
        return output
    }

    private static func sanitizedField(
        _ field: DiagnosticFieldValue,
        context: ErrorPresentationContext
    ) -> DiagnosticFieldValue {
        switch field {
        case .string(let value):
            return .string(ErrorPresentationPolicy.redactShareFacingText(
                value,
                context: context
            ))
        case .number, .bool:
            return field
        case .array(let values):
            return .array(values.map { sanitizedField($0, context: context) })
        case .object(let values):
            return .object(sanitizedObject(values, context: context))
        }
    }

    private static func sanitizedObject(
        _ values: [String: DiagnosticFieldValue],
        context: ErrorPresentationContext
    ) -> [String: DiagnosticFieldValue] {
        var sanitized: [String: DiagnosticFieldValue] = [:]
        for (index, pair) in values.sorted(by: { $0.key < $1.key }).enumerated() {
            let redactedKey = ErrorPresentationPolicy.redactShareFacingText(
                pair.key,
                context: context
            )
            let keyIsStructurallySafe = !pair.key.isEmpty
                && pair.key.utf8.count <= 64
                && pair.key.allSatisfy {
                    $0.isLetter || $0.isNumber
                        || $0 == "." || $0 == "_" || $0 == "-"
                }
            var safeKey = redactedKey == pair.key && keyIsStructurallySafe
                ? pair.key
                : "redactedField\(index)"
            while sanitized[safeKey] != nil {
                safeKey += "_"
            }
            sanitized[safeKey] = sanitizedField(pair.value, context: context)
        }
        return sanitized
    }

    static func canonicalPreviewFilename(_ proposed: String) -> String {
        let pathExtension = URL(fileURLWithPath: proposed)
            .pathExtension
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return pathExtension.isEmpty
            ? "preview"
            : "preview.\(pathExtension.prefix(12))"
    }

    static func encodedShareSafeEvidence(
        _ artifact: DiagnosticEvidenceArtifact,
        context: ErrorPresentationContext
    ) -> Data? {
        guard (try? DiagnosticEvidenceValidator.validate(
            artifact,
            expectedOperationId: artifact.operationId
        )) != nil else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(artifact),
              let text = String(data: data, encoding: .utf8),
              ErrorPresentationPolicy.redactShareFacingText(
                text,
                context: context
              ) == text,
              ErrorPresentationPolicy.redactShareFacingText(
                artifact.evidenceId,
                context: context
              ) == artifact.evidenceId
        else {
            return nil
        }
        return data
    }

    private static func safeReason(
        _ reason: String,
        context: ErrorPresentationContext
    ) -> String {
        let safe = ErrorPresentationPolicy.redactShareFacingText(
            reason,
            context: context
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? "not supplied" : String(safe.prefix(512))
    }
}

/// Resolves preview film bytes only after exact, per-export opt-in. Candidate
/// discovery reads metadata already held by the UI; `resolve` is the sole
/// file-read boundary and checks that consent still matches first.
public enum DiagnosticBundleRasterPolicy {
    public static func candidate(
        thumbnails: [Int: Thumbnail]
    ) -> DiagnosticPreviewConsent? {
        for frameIndex in thumbnails.keys.sorted() {
            guard let imagePath = thumbnails[frameIndex]?.imagePath,
                  !imagePath.isEmpty
            else { continue }
            let pathExtension = URL(fileURLWithPath: imagePath).pathExtension
            let filename = DiagnosticBundleBuilder.canonicalPreviewFilename(
                pathExtension.isEmpty ? "preview" : "preview.\(pathExtension)"
            )
            return DiagnosticPreviewConsent(
                frameIndex: frameIndex,
                sourcePath: imagePath,
                filename: filename
            )
        }
        return nil
    }

    public static func resolve(
        consent: DiagnosticPreviewConsent,
        currentCandidate: DiagnosticPreviewConsent?,
        readFile: (String) -> Data?
    ) -> (raster: DiagnosticBundleBuilder.PreviewRaster?, unavailableReason: String?) {
        guard consent == currentCandidate else {
            return (nil, "the consented film preview changed before export")
        }
        guard let data = readFile(consent.sourcePath) else {
            return (nil, "the consented film preview image file is missing or unreadable")
        }
        return (
            DiagnosticBundleBuilder.PreviewRaster(
                filename: consent.filename,
                data: data
            ),
            nil
        )
    }
}

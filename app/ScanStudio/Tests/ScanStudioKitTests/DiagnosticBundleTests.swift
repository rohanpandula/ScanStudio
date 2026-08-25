import Foundation
import Testing

@testable import ScanStudioKit

/// Minimal reader for the exact "stored" (uncompressed) ZIP shape
/// `StoredZipWriter` produces -- enough to round-trip-verify contents
/// without depending on a system unzip tool or a third-party archive
/// library in the test target.
private func readStoredZipEntries(_ data: Data) throws -> [(name: String, data: Data)] {
    var entries: [(name: String, data: Data)] = []
    var offset = data.startIndex
    func readUInt16LE(_ at: Data.Index) -> UInt16 {
        UInt16(data[at]) | (UInt16(data[at + 1]) << 8)
    }
    func readUInt32LE(_ at: Data.Index) -> UInt32 {
        UInt32(data[at]) | (UInt32(data[at + 1]) << 8)
            | (UInt32(data[at + 2]) << 16) | (UInt32(data[at + 3]) << 24)
    }

    while offset < data.endIndex {
        let signature = readUInt32LE(offset)
        guard signature == 0x0403_4b50 else { break }
        let compressedSize = Int(readUInt32LE(offset + 18))
        let nameLength = Int(readUInt16LE(offset + 26))
        let extraLength = Int(readUInt16LE(offset + 28))
        let nameStart = offset + 30
        let nameEnd = nameStart + nameLength
        let name = String(decoding: data[nameStart..<nameEnd], as: UTF8.self)
        let dataStart = nameEnd + extraLength
        let dataEnd = dataStart + compressedSize
        entries.append((name: name, data: data[dataStart..<dataEnd]))
        offset = dataEnd
    }
    return entries
}

@Suite("Stored zip writer")
struct StoredZipWriterTests {
    @Test("round-trips filenames and bytes exactly, including an empty entry")
    func roundTrips() throws {
        let entries: [StoredZipWriter.Entry] = [
            .init(name: "diagnostics.jsonl", data: Data(#"{"event":"session.started"}"#.utf8)),
            .init(name: "report.txt", data: Data("ScanStudio error report\n".utf8)),
            .init(name: "empty.txt", data: Data()),
        ]

        let zip = StoredZipWriter.write(entries)

        #expect(zip.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]))
        // The 22-byte End Of Central Directory record is the tail of the
        // file whenever the (unused) archive comment is empty, as here --
        // its signature is the record's first 4 bytes, not the file's last 4.
        #expect(zip.suffix(22).prefix(4) == Data([0x50, 0x4b, 0x05, 0x06]))
        let readBack = try readStoredZipEntries(zip)
        #expect(readBack.map(\.name) == entries.map(\.name))
        #expect(readBack.map(\.data) == entries.map(\.data))
    }

    @Test("an empty entry list still produces a well-formed (empty) archive")
    func emptyArchive() throws {
        let zip = StoredZipWriter.write([])
        #expect(zip.count == 22, "an empty archive is exactly one EOCD record")
        #expect(zip.prefix(4) == Data([0x50, 0x4b, 0x05, 0x06]))
        #expect(try readStoredZipEntries(zip).isEmpty)
    }
}

@Suite("Diagnostic bundle builder")
struct DiagnosticBundleBuilderTests {
    @Test("includes the diagnostics log, report text, and raster when one is available")
    func entriesWithRaster() throws {
        let consent = DiagnosticPreviewConsent(
            frameIndex: 1,
            sourcePath: "/fake/frame1.png",
            filename: "preview.png"
        )
        let entries = DiagnosticBundleBuilder.makeEntries(
            diagnosticsJSONL: Data(#"{"event":"session.started"}"#.utf8),
            reportText: "ScanStudio error report\nError code: NOT_CONNECTED",
            redactionContext: .init(),
            preview: .included(
                consent: consent,
                raster: .init(filename: "preview.png", data: Data([0x89, 0x50, 0x4e, 0x47]))
            ),
            evidence: .unavailable(reason: "no bounded evidence was expected")
        )

        let names = Set(entries.map(\.name))
        #expect(names == ["diagnostics.jsonl", "report.txt", "preview.png", "manifest.txt"])

        let manifest = try #require(entries.first { $0.name == "manifest.txt" })
        let manifestText = String(decoding: manifest.data, as: UTF8.self)
        #expect(manifestText.contains("preview.png: explicitly included film content from frame 1"))
        #expect(manifestText.contains("bounded evidence: unavailable (no bounded evidence was expected)"))

        let raster = try #require(entries.first { $0.name == "preview.png" })
        #expect(raster.data == Data([0x89, 0x50, 0x4e, 0x47]))
    }

    @Test("records the specific unavailability reason instead of silently dropping the raster")
    func entriesWithoutRaster() throws {
        let entries = DiagnosticBundleBuilder.makeEntries(
            diagnosticsJSONL: Data(),
            reportText: "ScanStudio error report",
            redactionContext: .init(),
            preview: .unavailable(
                reason: "the consented film preview image file is missing or unreadable"
            ),
            evidence: .unavailable(reason: "no bounded evidence was expected")
        )

        #expect(entries.map(\.name).sorted() == ["diagnostics.jsonl", "manifest.txt", "report.txt"])
        let manifest = try #require(entries.first { $0.name == "manifest.txt" })
        let manifestText = String(decoding: manifest.data, as: UTF8.self)
        #expect(
            manifestText.contains(
                "film preview: unavailable (the consented film preview image file is missing or unreadable)"
            )
        )
    }

    @Test("the default privacy choice excludes film content even when a candidate exists")
    func privacyDefaultExcludesCandidate() throws {
        let candidate = DiagnosticPreviewConsent(
            frameIndex: 4,
            sourcePath: "/Users/private/roll/frame4.tif",
            filename: "preview.tif"
        )
        let entries = DiagnosticBundleBuilder.makeEntries(
            diagnosticsJSONL: Data(),
            reportText: "ScanStudio error report",
            redactionContext: .init(),
            preview: .excludedByPrivacyDefault(candidate: candidate),
            evidence: .unavailable(reason: "not expected")
        )

        #expect(entries.map(\.name).sorted() == ["diagnostics.jsonl", "manifest.txt", "report.txt"])
        let manifest = try #require(entries.first { $0.name == "manifest.txt" })
        let text = String(decoding: manifest.data, as: UTF8.self)
        #expect(text.contains("film preview: excluded by privacy default"))
        #expect(text.contains("available frame: 4"))
        #expect(!text.contains(candidate.sourcePath))
    }

    @Test("share-facing ZIP redacts every input route and contains no raster bytes by default")
    func defaultZipIsShareSafeAcrossEveryEntry() throws {
        struct Fixture: Decodable {
            let username: String
            let absolutePaths: [String]
            let projectName: String
            let filmMetadata: [String]
            let deviceIdentifier: String
            let rasterMarker: String
        }
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "diagnostic-share-safety",
                withExtension: "json"
            )
        )
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        let timelineEntry = SessionDiagnosticEntry(
            timestamp: "2026-08-23T00:00:00Z",
            sessionId: "private-session-4815",
            event: "fixture.failed",
            fields: [
                "path": .string(fixture.absolutePaths[0]),
                "project": .string(fixture.projectName),
                "filmStock": .string(fixture.filmMetadata[0]),
                "deviceId": .string(fixture.deviceIdentifier),
                fixture.projectName: .string("sensitive key route"),
                "nested": .object([
                    fixture.deviceIdentifier: .bool(true),
                ]),
            ]
        )
        var diagnostics = try JSONEncoder().encode(timelineEntry)
        diagnostics.append(0x0A)
        let report = ([fixture.username, fixture.projectName, fixture.deviceIdentifier]
            + fixture.absolutePaths + fixture.filmMetadata)
            .joined(separator: "\n")
        let candidate = DiagnosticPreviewConsent(
            frameIndex: 1,
            sourcePath: fixture.absolutePaths[1],
            filename: "preview.tif"
        )
        let context = ErrorPresentationContext(
            selectedPaths: fixture.absolutePaths,
            filmMetadataValues: [fixture.projectName] + fixture.filmMetadata,
            deviceIdentifiers: [fixture.deviceIdentifier],
            diagnosticSessionId: "private-session-4815",
            diagnosticLogPath: fixture.absolutePaths[2]
        )

        let zip = StoredZipWriter.write(DiagnosticBundleBuilder.makeEntries(
            diagnosticsJSONL: diagnostics,
            reportText: report,
            redactionContext: context,
            preview: .excludedByPrivacyDefault(candidate: candidate),
            evidence: .unavailable(reason: "fixture has no bounded witness")
        ))
        let entries = try readStoredZipEntries(zip)
        #expect(Set(entries.map(\.name)) == ["diagnostics.jsonl", "report.txt", "manifest.txt"])

        let forbidden = [
            fixture.username,
            fixture.projectName,
            fixture.deviceIdentifier,
            fixture.rasterMarker,
            "private-session-4815",
        ] + fixture.absolutePaths + fixture.filmMetadata
        for entry in entries {
            let searchable = entry.name + "\n" + String(decoding: entry.data, as: UTF8.self)
            for value in forbidden {
                #expect(!searchable.localizedCaseInsensitiveContains(value))
            }
        }
    }
}

@Suite("Diagnostic bundle raster policy")
struct DiagnosticBundleRasterPolicyTests {
    @Test("an empty session honestly reports it never had a roll preview")
    func noThumbnails() {
        #expect(DiagnosticBundleRasterPolicy.candidate(thumbnails: [:]) == nil)
    }

    @Test("a thumbnail with no image path is reported, not silently skipped")
    func thumbnailWithoutImagePath() {
        let thumbnails: [Int: Thumbnail] = [
            1: Thumbnail(brightness: 0.5, tint: 0, imagePath: nil),
        ]
        #expect(DiagnosticBundleRasterPolicy.candidate(thumbnails: thumbnails) == nil)
    }

    @Test("a fake filesystem miss reports the file as missing, not silently skipped")
    func imageFileUnreadable() {
        let thumbnails: [Int: Thumbnail] = [
            1: Thumbnail(brightness: nil, tint: nil, imagePath: "/fake/frame1.tif"),
        ]
        let candidate = DiagnosticBundleRasterPolicy.candidate(thumbnails: thumbnails)
        let (raster, reason) = DiagnosticBundleRasterPolicy.resolve(
            consent: candidate!,
            currentCandidate: candidate,
            readFile: { _ in nil }
        )
        #expect(raster == nil)
        #expect(reason == "the consented film preview image file is missing or unreadable")
    }

    @Test("resolves the lowest-indexed frame's image against a fake filesystem, naming it by extension")
    func resolvesLowestIndexedFrame() throws {
        let fakeFilesystem: [String: Data] = [
            "/fake/frame3.tif": Data("wrong frame".utf8),
            "/fake/frame1.tif": Data("roll preview bytes".utf8),
        ]
        let thumbnails: [Int: Thumbnail] = [
            3: Thumbnail(brightness: nil, tint: nil, imagePath: "/fake/frame3.tif"),
            1: Thumbnail(brightness: nil, tint: nil, imagePath: "/fake/frame1.tif"),
        ]

        let candidate = try #require(
            DiagnosticBundleRasterPolicy.candidate(thumbnails: thumbnails)
        )
        let (raster, reason) = DiagnosticBundleRasterPolicy.resolve(
            consent: candidate,
            currentCandidate: candidate,
            readFile: { fakeFilesystem[$0] }
        )

        #expect(reason == nil)
        let resolved = try #require(raster)
        #expect(resolved.filename == "preview.tif")
        #expect(resolved.data == Data("roll preview bytes".utf8))
    }

    @Test("consent is bound to one exact frame and path before bytes are read")
    func changedCandidateFailsBeforeRead() throws {
        let consent = DiagnosticPreviewConsent(
            frameIndex: 1,
            sourcePath: "/fake/frame1.tif",
            filename: "preview.tif"
        )
        let replacement = DiagnosticPreviewConsent(
            frameIndex: 1,
            sourcePath: "/fake/replacement-frame1.tif",
            filename: "preview.tif"
        )
        var readCount = 0

        let (raster, reason) = DiagnosticBundleRasterPolicy.resolve(
            consent: consent,
            currentCandidate: replacement,
            readFile: { _ in
                readCount += 1
                return Data("should not be read".utf8)
            }
        )

        #expect(raster == nil)
        #expect(reason == "the consented film preview changed before export")
        #expect(readCount == 0)
    }

    @Test("candidate and final ZIP use the same canonical filename")
    func candidateFilenameMatchesArchivePolicy() throws {
        let candidate = try #require(DiagnosticBundleRasterPolicy.candidate(
            thumbnails: [
                1: Thumbnail(
                    brightness: nil,
                    tint: nil,
                    imagePath: "/fake/frame1.TI%F"
                ),
            ]
        ))

        #expect(candidate.filename == "preview.tif")
    }
}

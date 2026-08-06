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
        let entries = DiagnosticBundleBuilder.makeEntries(
            diagnosticsJSONL: Data(#"{"event":"session.started"}"#.utf8),
            reportText: "ScanStudio error report\nError code: NOT_CONNECTED",
            previewRaster: .init(filename: "preview.png", data: Data([0x89, 0x50, 0x4e, 0x47])),
            unavailableRasterReason: nil
        )

        let names = Set(entries.map(\.name))
        #expect(names == ["diagnostics.jsonl", "report.txt", "preview.png", "manifest.txt"])

        let manifest = try #require(entries.first { $0.name == "manifest.txt" })
        let manifestText = String(decoding: manifest.data, as: UTF8.self)
        #expect(manifestText.contains("preview.png: the roll preview raster"))
        #expect(!manifestText.contains("not available"))

        let raster = try #require(entries.first { $0.name == "preview.png" })
        #expect(raster.data == Data([0x89, 0x50, 0x4e, 0x47]))
    }

    @Test("records the specific unavailability reason instead of silently dropping the raster")
    func entriesWithoutRaster() throws {
        let entries = DiagnosticBundleBuilder.makeEntries(
            diagnosticsJSONL: Data(),
            reportText: "ScanStudio error report",
            previewRaster: nil,
            unavailableRasterReason: "the roll preview image file is missing or unreadable"
        )

        #expect(entries.map(\.name).sorted() == ["diagnostics.jsonl", "manifest.txt", "report.txt"])
        let manifest = try #require(entries.first { $0.name == "manifest.txt" })
        let manifestText = String(decoding: manifest.data, as: UTF8.self)
        #expect(
            manifestText.contains(
                "raster: not available in this build (the roll preview image file is missing or unreadable)"
            )
        )
    }
}

@Suite("Diagnostic bundle raster policy")
struct DiagnosticBundleRasterPolicyTests {
    @Test("an empty session honestly reports it never had a roll preview")
    func noThumbnails() {
        let (raster, reason) = DiagnosticBundleRasterPolicy.resolve(
            thumbnails: [:],
            readFile: { _ in Data() }
        )
        #expect(raster == nil)
        #expect(reason == "no roll preview in this session")
    }

    @Test("a thumbnail with no image path is reported, not silently skipped")
    func thumbnailWithoutImagePath() {
        let thumbnails: [Int: Thumbnail] = [
            1: Thumbnail(brightness: 0.5, tint: 0, imagePath: nil),
        ]
        let (raster, reason) = DiagnosticBundleRasterPolicy.resolve(
            thumbnails: thumbnails,
            readFile: { _ in Data() }
        )
        #expect(raster == nil)
        #expect(reason == "the roll preview has no locally-known image path")
    }

    @Test("a fake filesystem miss reports the file as missing, not silently skipped")
    func imageFileUnreadable() {
        let thumbnails: [Int: Thumbnail] = [
            1: Thumbnail(brightness: nil, tint: nil, imagePath: "/fake/frame1.tif"),
        ]
        let (raster, reason) = DiagnosticBundleRasterPolicy.resolve(
            thumbnails: thumbnails,
            readFile: { _ in nil }
        )
        #expect(raster == nil)
        #expect(reason == "the roll preview image file is missing or unreadable")
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

        let (raster, reason) = DiagnosticBundleRasterPolicy.resolve(
            thumbnails: thumbnails,
            readFile: { fakeFilesystem[$0] }
        )

        #expect(reason == nil)
        let resolved = try #require(raster)
        #expect(resolved.filename == "preview.tif")
        #expect(resolved.data == Data("roll preview bytes".utf8))
    }
}

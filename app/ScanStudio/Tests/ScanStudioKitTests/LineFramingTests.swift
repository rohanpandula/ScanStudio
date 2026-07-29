// Unit tests for `LineFramer` (D-14) — no process/pipe involved, exactly
// the standalone type `EngineClient` uses internally.

import Foundation
import Testing

@testable import ScanStudioKit

@Suite("LineFramer")
struct LineFramingTests {
    @Test("a chunk containing exactly one complete line yields one line")
    func singleCompleteLine() {
        var framer = LineFramer()
        let chunk = Data("{\"id\":1}\n".utf8)

        let lines = framer.feed(chunk)

        #expect(lines == ["{\"id\":1}"])
    }

    @Test("a JSON object split across two feed calls at an arbitrary offset reassembles correctly")
    func splitAcrossTwoFeeds() {
        var framer = LineFramer()
        let full = "{\"id\":1,\"method\":\"engine.hello\"}\n"
        let splitIndex = full.index(full.startIndex, offsetBy: 11) // arbitrary mid-object byte offset
        let firstHalf = String(full[full.startIndex..<splitIndex])
        let secondHalf = String(full[splitIndex...])

        let firstLines = framer.feed(Data(firstHalf.utf8))
        #expect(firstLines.isEmpty, "a chunk with no newline must yield zero lines")

        let secondLines = framer.feed(Data(secondHalf.utf8))
        #expect(secondLines == [String(full.dropLast())], "the newline-completing feed must return exactly one correctly-reassembled line")
    }

    @Test("a single chunk containing two complete lines yields both, in order")
    func twoLinesInOneChunk() {
        var framer = LineFramer()
        let chunk = Data("{\"a\":1}\n{\"b\":2}\n".utf8)

        let lines = framer.feed(chunk)

        #expect(lines == ["{\"a\":1}", "{\"b\":2}"])
    }

    @Test("a chunk with a complete line plus a trailing partial line returns the complete line now, and the remainder on a subsequent feed")
    func completeLinePlusTrailingPartial() {
        var framer = LineFramer()

        let firstChunk = Data("{\"a\":1}\n{\"b\":".utf8)
        let firstLines = framer.feed(firstChunk)
        #expect(firstLines == ["{\"a\":1}"])

        let secondChunk = Data("2}\n".utf8)
        let secondLines = framer.feed(secondChunk)
        #expect(secondLines == ["{\"b\":2}"])
    }

    @Test("feeding empty data is a no-op")
    func emptyFeedIsNoOp() {
        var framer = LineFramer()
        #expect(framer.feed(Data()).isEmpty)

        // A subsequent real line still frames correctly afterward.
        let lines = framer.feed(Data("{\"a\":1}\n".utf8))
        #expect(lines == ["{\"a\":1}"])
    }
}

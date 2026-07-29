import Testing

@testable import ScanStudioKit

@Suite("Histogram math")
struct HistogramMathTests {
    @Test("bins on an empty sample array returns binCount all-zero buckets")
    func binsEmptyArrayIsAllZero() {
        let counts = HistogramMath.bins(for: [])
        #expect(counts.count == HistogramMath.binCount)
        #expect(counts.allSatisfy { $0 == 0 })
    }

    @Test("every sample lands in exactly one bucket, so the total count is preserved")
    func binsPreserveTotalCount() {
        let samples: [UInt8] = (0..<256).map { UInt8($0) }
        let counts = HistogramMath.bins(for: samples)
        #expect(counts.reduce(0, +) == samples.count)
    }

    @Test("the minimum sample maps to the first bucket and the maximum to the last")
    func binsMapExtremesToEndpoints() {
        let lows = HistogramMath.bins(for: [0])
        let highs = HistogramMath.bins(for: [255])
        #expect(lows[0] == 1)
        #expect(highs[HistogramMath.binCount - 1] == 1)
    }

    @Test("a uniform sample array collapses into a single bucket")
    func binsUniformArraySingleBucket() {
        let counts = HistogramMath.bins(for: Array(repeating: 100, count: 16))
        #expect(counts.reduce(0, +) == 16)
        #expect(counts.filter { $0 != 0 }.count == 1)
    }

    @Test("neighboring samples straddling a bucket boundary fall into different buckets")
    func binsStraddleBoundary() {
        let counts = HistogramMath.bins(for: [7, 8])
        #expect(counts[0] == 1)
        #expect(counts[1] == 1)
    }
}

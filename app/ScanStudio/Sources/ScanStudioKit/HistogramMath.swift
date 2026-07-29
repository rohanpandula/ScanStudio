import Foundation

public struct RGBHistogram: Equatable, Sendable {
    public let red: [Int]
    public let green: [Int]
    public let blue: [Int]

    public init(red: [Int], green: [Int], blue: [Int]) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum HistogramMath {
    public static let binCount = 32

    public static func bins(for samples: [UInt8]) -> [Int] {
        var counts = [Int](repeating: 0, count: binCount)
        let bucketSpan = 256 / binCount
        for value in samples {
            counts[min(binCount - 1, Int(value) / bucketSpan)] += 1
        }
        return counts
    }
}

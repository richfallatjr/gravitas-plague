import Foundation

enum TuringPacketizer {
    static let maxSegmentsBeforeSplit = 5

    nonisolated static func packetize<T>(_ segments: [T]) -> [[T]] {
        guard !segments.isEmpty else { return [] }
        guard segments.count > maxSegmentsBeforeSplit else {
            return [segments]
        }

        let splitIndex = Int(ceil(Double(segments.count) / 2.0))
        return [
            Array(segments[..<splitIndex]),
            Array(segments[splitIndex...])
        ]
    }
}

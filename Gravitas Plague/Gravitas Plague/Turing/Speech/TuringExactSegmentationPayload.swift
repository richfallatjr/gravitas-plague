import Foundation

struct TuringExactSegmentationPayload: Codable, Sendable {
    struct Segment: Codable, Sendable {
        let index: Int
        let spokenText: String
    }

    let version: Int
    let chunkIndex: Int
    let focusStartUTF16: Int
    let focusEndUTF16: Int
    let targetSeconds: Double
    let maxSeconds: Double
    let segments: [Segment]
}

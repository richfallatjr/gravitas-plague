import Foundation

struct TuringExactSegmentationPayload: Codable, Sendable {
    struct Segment: Codable, Sendable {
        let index: Int?
        let spokenText: String
    }

    let segments: [Segment]
}

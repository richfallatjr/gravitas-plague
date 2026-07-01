import Foundation

struct TuringExactSpeechSegment: Codable, Sendable, Hashable {
    let globalIndex: Int
    let chunkIndex: Int
    let localIndex: Int
    let absoluteStartUTF16: Int
    let absoluteEndUTF16: Int
    let text: String
    let emotion: String
}

struct TuringExactSegmentationChunkResult: Sendable, Hashable {
    let chunkIndex: Int
    let segments: [TuringExactSpeechSegment]
}

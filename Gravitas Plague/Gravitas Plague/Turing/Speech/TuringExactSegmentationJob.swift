import Foundation

struct TuringExactSegmentationJob: Sendable, Hashable, Codable {
    let index: Int
    let focusStartUTF16: Int
    let focusEndUTF16: Int
    let contextStartUTF16: Int
    let contextEndUTF16: Int
    let prefixContext: String
    let focusText: String
    let suffixContext: String
}

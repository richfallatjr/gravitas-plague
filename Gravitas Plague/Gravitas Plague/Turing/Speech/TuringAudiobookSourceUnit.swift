import Foundation

struct TuringAudiobookSourceUnit: Sendable, Hashable {
    let startUTF16: Int
    let endUTF16: Int
    let wordCount: Int
}

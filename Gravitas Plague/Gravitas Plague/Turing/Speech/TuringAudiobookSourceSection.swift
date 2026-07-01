import Foundation

struct TuringAudiobookSourceSection: Sendable, Hashable, Identifiable {
    let index: Int
    let sourceStartUTF16: Int
    let sourceEndUTF16: Int
    let estimatedWordCount: Int

    var id: Int { index }
}

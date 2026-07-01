import Foundation

struct TuringAudiobookSourceSectionPolicy: Sendable, Equatable {
    let targetWords: Int = 120
    let minWords: Int = 45
    let maxWords: Int = 210
    let maxChars: Int = 2400
}

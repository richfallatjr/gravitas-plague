import Foundation

struct QwenPhase0SmokeRequest: Sendable, Equatable {
    let text: String
    let language: String
    let maxTokens: Int
    let temperature: Float
    let topP: Float
    let repetitionPenalty: Float

    init(
        text: String,
        language: String = "English",
        maxTokens: Int = 96,
        temperature: Float = 0.0,
        topP: Float = 1.0,
        repetitionPenalty: Float = 1.0
    ) {
        self.text = text
        self.language = language
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
    }
}

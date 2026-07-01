import Foundation

struct TuringSpeechSegment: Codable, Sendable, Hashable {
    let text: String
    let emotion: String
}

struct QwenGenerationSettings: Codable, Sendable, Hashable {
    let language: String
    let sampleRate: Int
    let temperature: Double
    let topP: Double
    let repetitionPenalty: Double
    let maxTokens: Int
    let seed: UInt64?

    init(
        language: String,
        sampleRate: Int,
        temperature: Double,
        topP: Double,
        repetitionPenalty: Double = 1.0,
        maxTokens: Int,
        seed: UInt64?
    ) {
        self.language = language
        self.sampleRate = sampleRate
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.maxTokens = maxTokens
        self.seed = seed
    }
}

struct QwenWaveform: Sendable, Hashable {
    let samples: [Float]
    let sampleRate: Int
    let channelCount: Int
}

struct TuringRenderedSegment: Sendable, Hashable {
    let segmentIndex: Int
    let renderID: String
    let fileURL: URL
    let durationSeconds: TimeInterval
    let isTransient: Bool
    let sampleRate: Int
    let channelCount: Int
    @available(*, deprecated, message: "Generated Qwen WAV cache removed; use renderID.")
    let cacheKey: String
}

struct TuringRadioEffectProfile: Codable, Sendable, Hashable {
    let id: String
    let revision: String

    static let none: TuringRadioEffectProfile? = nil
}

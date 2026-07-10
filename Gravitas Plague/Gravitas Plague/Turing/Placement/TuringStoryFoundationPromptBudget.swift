import Foundation

enum TuringStoryFoundationPromptBudget {
    static let preferredPromptTokens = 1_800
    static let hardPromptTokens = 2_300
    static let minimumReservedTokens = 1_200
    static let maximumPromptUTF8Bytes = 8_500
    static let hotspotReductionSequence = [32, 28, 24, 20, 16]
    static let contextSize = 4_096
    static let conservativeMaximumPromptTokens = 1_900

    struct Result: Codable, Sendable {
        let contextSize: Int
        let tokenCountMode: String
        let promptTokens: Int
        let promptUTF8Bytes: Int
        let hotspotCount: Int
        let reservedTokens: Int
        let withinBudget: Bool
        let withinPreferredBudget: Bool
    }

    static func evaluate(
        prompt: String,
        hotspotCount: Int
    ) -> Result {
        let bytes = prompt.utf8.count
        // The deployed SDK does not expose a public tokenizer count API here.
        let estimatedTokens = Int(ceil(Double(bytes) / 3.0))
        let reserved = contextSize - estimatedTokens
        let within = estimatedTokens <= hardPromptTokens &&
            estimatedTokens <= conservativeMaximumPromptTokens &&
            reserved >= minimumReservedTokens &&
            bytes <= maximumPromptUTF8Bytes
        return Result(
            contextSize: contextSize,
            tokenCountMode: "conservativeUTF8",
            promptTokens: estimatedTokens,
            promptUTF8Bytes: bytes,
            hotspotCount: hotspotCount,
            reservedTokens: reserved,
            withinBudget: within,
            withinPreferredBudget: within && estimatedTokens <= preferredPromptTokens
        )
    }
}

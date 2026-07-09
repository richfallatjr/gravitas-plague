import Foundation

struct VoicePromptRequest: Codable, Sendable, Hashable {
    let id: String
    let speaker: String
    let voiceID: String
    let voiceVariantID: String?
    let characterProfileID: String
    let intent: String
    let emotion: String
    let prerecordingTranscript: String?
    let voicePromptSeedIntent: String?
}

struct ConversationPromptNoBibleRequest: Codable, Sendable, Hashable {
    let id: String
    let speaker: String
    let voiceID: String
    let voiceVariantID: String?
    let characterProfileID: String
    let playerDictation: String
    let episodeStateForWordsOnly: String
    let emotion: String
    let prerecordingTranscript: String?
    let lastVoicePromptSeed: TuringConversationSeed?
}

struct TuringDialoguePlan: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let segments: [TuringSpeechSegment]
}

struct TuringVoicePromptPlan: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let segments: [TuringSpeechSegment]
    let conversationSeed: TuringConversationSeed
}

struct TuringCharacterProfile: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let characterID: String
    let displayName: String
    let defaultVoiceID: String
    let writeup: String

    var promptText: String {
        """
        \(displayName) (\(characterID))
        Voice: \(defaultVoiceID)
        \(writeup)
        """
    }

    var voicePromptPromptText: String {
        if characterID == "big_mike" {
            return """
            Big Mike (big_mike)
            Voice: \(defaultVoiceID)
            Big Mike is Rich's neighbor, best friend, and closest radio contact. He sounds like a large, exhausted man trying to keep his friend calm and responsive through a weak connection. He is direct, streetwise, sarcastic, protective, practical, and tired. His care comes out as irritation, not sentiment. He should sound like a real friend checking in, not a narrator, assistant, tutorial voice, or mission dispatcher.
            """
        }

        return promptText
    }
}

struct TuringCharacterProfileStore: Sendable {
    func profile(
        id: String
    ) throws -> TuringCharacterProfile {
        try TuringResourceLoader.decodeResource(
            TuringCharacterProfile.self,
            resourcePath: "Turing/Characters/\(id).json"
        )
    }
}

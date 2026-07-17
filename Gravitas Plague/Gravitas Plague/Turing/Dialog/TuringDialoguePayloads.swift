import Foundation

struct VoicePromptRequest: Codable, Sendable, Hashable {
    let id: String
    let characterProfileID: String
    let promptContext: String
    let prerecordingTranscript: String

    init(
        id: String,
        characterProfileID: String,
        promptContext: String,
        prerecordingTranscript: String
    ) {
        self.id = id
        self.characterProfileID = characterProfileID
        self.promptContext = promptContext
        self.prerecordingTranscript = prerecordingTranscript
    }
}

struct ConversationPromptNoBibleRequest: Codable, Sendable, Hashable {
    let id: String
    let characterProfileID: String
    let userInput: String
    let promptContext: String
    let prerecordingTranscript: String
    let promptVoiceID: String
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

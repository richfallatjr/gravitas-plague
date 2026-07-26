import Foundation

struct VoicePromptRequest: Codable, Sendable, Hashable {
    let id: String
    let characterProfileID: String
    let listenerProfileID: String
    let promptContext: String
    let prerecordingTranscript: String
    let storyIntent: String?

    init(
        id: String,
        characterProfileID: String,
        listenerProfileID: String,
        promptContext: String,
        prerecordingTranscript: String,
        storyIntent: String? = nil
    ) {
        self.id = id
        self.characterProfileID = characterProfileID
        self.listenerProfileID = listenerProfileID
        self.promptContext = promptContext
        self.prerecordingTranscript = prerecordingTranscript
        self.storyIntent = storyIntent
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

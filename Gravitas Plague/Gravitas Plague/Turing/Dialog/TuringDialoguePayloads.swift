import Foundation

struct VoicePromptRequest: Codable, Sendable, Hashable {
    let id: String
    let speaker: String
    let voiceID: String
    let characterProfileID: String
    let intent: String
    let emotion: String
}

struct ConversationPromptNoBibleRequest: Codable, Sendable, Hashable {
    let id: String
    let speaker: String
    let voiceID: String
    let characterProfileID: String
    let playerDictation: String
    let episodeStateForWordsOnly: String
    let emotion: String
}

struct TuringDialoguePlan: Codable, Sendable, Hashable {
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

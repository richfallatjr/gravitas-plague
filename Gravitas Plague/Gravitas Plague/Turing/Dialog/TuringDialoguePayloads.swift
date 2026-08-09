import Foundation

struct VoicePromptRequest: Codable, Sendable, Hashable {
    let id: String
    let characterProfileID: String
    let listenerProfileID: String
    let promptContext: String
    let prerecordingTranscript: String
    let storyIntent: String?
    let promptTemplateID: TuringVoicePromptTemplateID
    let communicationMedium: String?

    init(
        id: String,
        characterProfileID: String,
        listenerProfileID: String,
        promptContext: String,
        prerecordingTranscript: String,
        storyIntent: String? = nil,
        promptTemplateID: TuringVoicePromptTemplateID = .characterIntent,
        communicationMedium: String? = nil
    ) {
        self.id = id
        self.characterProfileID = characterProfileID
        self.listenerProfileID = listenerProfileID
        self.promptContext = promptContext
        self.prerecordingTranscript = prerecordingTranscript
        self.storyIntent = storyIntent
        self.promptTemplateID = promptTemplateID
        self.communicationMedium = communicationMedium
    }
}

struct ConversationPromptNoBibleRequest: Codable, Sendable, Hashable {
    let id: String
    let characterProfileID: String
    let userInput: String
    let promptContext: String
    let prerecordingTranscript: String
    let promptVariant: TuringConversationPromptVariant

    init(
        id: String,
        characterProfileID: String,
        userInput: String,
        promptContext: String,
        prerecordingTranscript: String,
        promptVariant: TuringConversationPromptVariant = .standard
    ) {
        self.id = id
        self.characterProfileID = characterProfileID
        self.userInput = userInput
        self.promptContext = promptContext
        self.prerecordingTranscript = prerecordingTranscript
        self.promptVariant = promptVariant
    }
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
    let profileID: String?
    let characterID: String
    let episodeID: String?
    let displayName: String
    let defaultVoiceID: String
    let writeup: String

    var effectiveProfileID: String {
        profileID ?? characterID
    }

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
        let profile = try TuringResourceLoader.decodeResource(
            TuringCharacterProfile.self,
            resourcePath: "Turing/Characters/\(id).json"
        )
        guard profile.effectiveProfileID == id else {
            throw TuringRuntimeError.invalidConfig(
                "Character profile ID mismatch. Expected \(id), got \(profile.effectiveProfileID)."
            )
        }
        return profile
    }
}

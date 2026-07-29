import Foundation

struct TuringAuthoredPromptVoiceContext: Sendable, Equatable {
    let voicePromptID: String
    let storyContext: String
}

enum TuringConversationPromptVariant:
    String,
    Codable,
    Sendable,
    Hashable
{
    case standard
    case scriptPoint05
    case roomObjectMemory
    case broadcasterRadio

    static func forScriptPointID(
        _ scriptPointID: String
    ) -> TuringConversationPromptVariant {
        scriptPointID == "prologue.scriptPoint05"
            ? .scriptPoint05
            : .standard
    }

    static func resolved(
        scriptPointID: String,
        promptTemplateID: TuringVoicePromptTemplateID
    ) -> TuringConversationPromptVariant {
        let established =
            Self.forScriptPointID(scriptPointID)
        return established == .scriptPoint05
            ? .scriptPoint05
            : promptTemplateID.conversationVariant
    }

    var resourcePath: String {
        switch self {
        case .standard:
            return "Turing/Prompts/conversationPrompt_playerTurn_noBible.txt"
        case .scriptPoint05:
            return "Turing/Prompts/conversationPrompt_scriptPoint05.txt"
        case .roomObjectMemory:
            return "Turing/Prompts/conversationPrompt_roomObjectMemory.txt"
        case .broadcasterRadio:
            return "Turing/Prompts/conversationPrompt_broadcasterRadio.txt"
        }
    }

    var foundationPurpose: String {
        switch self {
        case .standard:
            return "conversationPrompt_playerTurn_noBible"
        case .scriptPoint05:
            return "conversationPrompt_scriptPoint05"
        case .roomObjectMemory:
            return "conversationPrompt_roomObjectMemory"
        case .broadcasterRadio:
            return "conversationPrompt_broadcasterRadio"
        }
    }
}

actor TuringConversationInputStore {
    static let shared = TuringConversationInputStore()

    private var promptVoiceStoryContextByKey: [String: String] = [:]
    private var prerecordingIDByKey: [String: String] = [:]
    private var prerecordingTranscriptByKey: [String: String] = [:]
    private var promptVariantByKey:
        [String: TuringConversationPromptVariant] = [:]

    func prerecordingTranscript(for key: String) -> String {
        prerecordingTranscriptByKey[key] ?? ""
    }

    func promptVoiceStoryContext(for key: String) -> String? {
        promptVoiceStoryContextByKey[key]
    }

    func promptVariant(
        for key: String
    ) -> TuringConversationPromptVariant {
        promptVariantByKey[key] ?? .standard
    }

    func updatePromptVariant(
        _ variant: TuringConversationPromptVariant,
        for key: String
    ) {
        promptVariantByKey[key] = variant
        print("""
        [TuringConversationInput] prompt variant updated
          key: \(key)
          variant: \(variant.rawValue)
        """)
    }

    func updatePromptVoiceStoryContext(
        _ storyContext: String,
        for key: String
    ) {
        promptVoiceStoryContextByKey[key] = storyContext
        print("""
        [TuringConversationInput] authored promptVoice Story Context updated
          key: \(key)
          storyContextUTF16: \(storyContext.utf16.count)
          storyContextSHA256: \(TuringFlowHash.sha256(storyContext))
        """)
    }

    func updatePrerecording(
        id: String,
        transcript: String,
        for key: String
    ) {
        prerecordingIDByKey[key] = id
        prerecordingTranscriptByKey[key] = transcript
        print("""
        [TuringConversationInput] prerecording transcript updated
          key: \(key)
          prerecordingID: \(id)
          transcriptUTF16: \(transcript.utf16.count)
        """)
    }

    func clear(key: String) {
        promptVoiceStoryContextByKey.removeValue(forKey: key)
        prerecordingIDByKey.removeValue(forKey: key)
        prerecordingTranscriptByKey.removeValue(forKey: key)
        promptVariantByKey.removeValue(forKey: key)
    }

    func clearAll(reason: String) {
        promptVoiceStoryContextByKey.removeAll(keepingCapacity: false)
        prerecordingIDByKey.removeAll(keepingCapacity: false)
        prerecordingTranscriptByKey.removeAll(keepingCapacity: false)
        promptVariantByKey.removeAll(keepingCapacity: false)
        print("""
        [TuringConversationInput] cleared
          reason: \(reason)
        """)
    }
}

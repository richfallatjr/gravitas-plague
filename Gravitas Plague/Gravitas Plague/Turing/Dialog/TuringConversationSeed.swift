import Foundation

struct TuringAuthoredPromptVoiceContext: Sendable, Equatable {
    let voicePromptID: String
    let storyContext: String
}

actor TuringConversationInputStore {
    static let shared = TuringConversationInputStore()

    private var promptVoiceStoryContextByKey: [String: String] = [:]
    private var prerecordingIDByKey: [String: String] = [:]
    private var prerecordingTranscriptByKey: [String: String] = [:]

    func prerecordingTranscript(for key: String) -> String {
        prerecordingTranscriptByKey[key] ?? ""
    }

    func promptVoiceStoryContext(for key: String) -> String? {
        promptVoiceStoryContextByKey[key]
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
    }

    func clearAll(reason: String) {
        promptVoiceStoryContextByKey.removeAll(keepingCapacity: false)
        prerecordingIDByKey.removeAll(keepingCapacity: false)
        prerecordingTranscriptByKey.removeAll(keepingCapacity: false)
        print("""
        [TuringConversationInput] cleared
          reason: \(reason)
        """)
    }
}

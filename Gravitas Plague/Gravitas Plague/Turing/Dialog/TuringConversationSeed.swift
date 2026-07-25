import Foundation

struct TuringPromptVoiceSeed: Sendable, Equatable {
    let voicePromptID: String
    let promptContext: String
}

actor TuringConversationSeedStore {
    static let shared = TuringConversationSeedStore()

    private var promptVoiceSeedsByKey: [String: TuringPromptVoiceSeed] = [:]
    private var prerecordingIDByKey: [String: String] = [:]
    private var prerecordingTranscriptByKey: [String: String] = [:]

    func prerecordingTranscript(for key: String) -> String {
        prerecordingTranscriptByKey[key] ?? ""
    }

    func promptVoiceSeed(for key: String) -> TuringPromptVoiceSeed? {
        promptVoiceSeedsByKey[key]
    }

    func updatePromptVoiceSeed(
        _ seed: TuringPromptVoiceSeed,
        for key: String
    ) {
        promptVoiceSeedsByKey[key] = seed
        print("""
        [TuringConversationSeed] promptVoice seed updated
          key: \(key)
          voicePromptID: \(seed.voicePromptID)
          promptContextUTF16: \(seed.promptContext.utf16.count)
          promptContextSHA256: \(TuringFlowHash.sha256(seed.promptContext))
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
        [TuringConversationSeed] prerecording context updated
          key: \(key)
          prerecordingID: \(id)
          transcriptUTF16: \(transcript.utf16.count)
        """)
    }

    func clear(key: String) {
        promptVoiceSeedsByKey.removeValue(forKey: key)
        prerecordingIDByKey.removeValue(forKey: key)
        prerecordingTranscriptByKey.removeValue(forKey: key)
    }

    func clearAll(reason: String) {
        promptVoiceSeedsByKey.removeAll(keepingCapacity: false)
        prerecordingIDByKey.removeAll(keepingCapacity: false)
        prerecordingTranscriptByKey.removeAll(keepingCapacity: false)
        print("""
        [TuringConversationSeed] cleared
          reason: \(reason)
        """)
    }
}

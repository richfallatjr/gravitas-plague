import Foundation

struct TuringConversationSeed: Codable, Sendable, Hashable {
    let seedID: String
    let summary: String
    let currentAttitude: String
    let recentFacts: [String]
    let openThread: String

    static let empty = TuringConversationSeed(
        seedID: "",
        summary: "",
        currentAttitude: "",
        recentFacts: [],
        openThread: ""
    )

    var isEmptySeed: Bool {
        seedID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            currentAttitude.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            recentFacts.isEmpty &&
            openThread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var promptJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

struct TuringConversationPromptContext: Sendable, Hashable {
    let prerecordingID: String?
    let prerecordingTranscript: String
    let lastVoicePromptSeed: TuringConversationSeed

    static let empty = TuringConversationPromptContext(
        prerecordingID: nil,
        prerecordingTranscript: "",
        lastVoicePromptSeed: .empty
    )
}

actor TuringConversationSeedStore {
    static let shared = TuringConversationSeedStore()

    private var seedsByKey: [String: TuringConversationSeed] = [:]
    private var prerecordingIDByKey: [String: String] = [:]
    private var prerecordingTranscriptByKey: [String: String] = [:]

    func seed(for key: String) -> TuringConversationSeed {
        seedsByKey[key] ?? .empty
    }

    func context(for key: String) -> TuringConversationPromptContext {
        TuringConversationPromptContext(
            prerecordingID: prerecordingIDByKey[key],
            prerecordingTranscript: prerecordingTranscriptByKey[key] ?? "",
            lastVoicePromptSeed: seedsByKey[key] ?? .empty
        )
    }

    func updateSeed(_ seed: TuringConversationSeed?, for key: String) {
        guard let seed else { return }
        if seed.isEmptySeed {
            seedsByKey.removeValue(forKey: key)
        } else {
            seedsByKey[key] = seed
        }
        print("""
        [TuringConversationSeed] updated
          key: \(key)
          seedID: \(seed.seedID)
          empty: \(seed.isEmptySeed)
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
        seedsByKey.removeValue(forKey: key)
        prerecordingIDByKey.removeValue(forKey: key)
        prerecordingTranscriptByKey.removeValue(forKey: key)
    }

    func clearAll(reason: String) {
        seedsByKey.removeAll(keepingCapacity: false)
        prerecordingIDByKey.removeAll(keepingCapacity: false)
        prerecordingTranscriptByKey.removeAll(keepingCapacity: false)
        print("""
        [TuringConversationSeed] cleared
          reason: \(reason)
        """)
    }
}

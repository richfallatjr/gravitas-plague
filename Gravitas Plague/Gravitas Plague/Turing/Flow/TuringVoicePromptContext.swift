import Foundation

struct TuringVoicePromptContext: Codable, Sendable, Hashable {
    let dialogueHistory: [Turn]
    let authoredPrerecording: AuthoredPrerecording

    struct Turn: Codable, Sendable, Hashable {
        enum Source: String, Codable, Sendable, Hashable {
            case authoredPrerecording
            case generatedVoicePrompt
            case playerDictation
            case generatedConversation
        }

        let turnID: String
        let scriptPointID: String?
        let speakerID: String
        let text: String
        let source: Source
    }

    struct AuthoredPrerecording: Codable, Sendable, Hashable {
        let prerecordingID: String
        let speakerID: String
        let transcript: String
        let alreadySpoken: Bool
        let generatedResponseMustContinueAfterIt: Bool
    }

    var dialogueHistoryJSON: String {
        Self.encodeJSON(dialogueHistory)
    }

    var authoredPrerecordingJSON: String {
        Self.encodeJSON(authoredPrerecording)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}


extension TuringVoicePromptContext.AuthoredPrerecording {
    var promptJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

actor TuringDialogueHistoryStore {
    static let shared = TuringDialogueHistoryStore()

    private var turnsByConversationKey:
        [String: [TuringVoicePromptContext.Turn]] = [:]

    func recentTurns(
        for conversationKey: String,
        limit: Int
    ) -> [TuringVoicePromptContext.Turn] {
        let turns = turnsByConversationKey[conversationKey] ?? []
        return Array(turns.suffix(max(0, limit)))
    }

    func makeVoicePromptContext(
        conversationKey: String,
        historyLimit: Int,
        prerecording: TuringPrerecordingDescriptor
    ) -> TuringVoicePromptContext {
        TuringVoicePromptContext(
            dialogueHistory: recentTurns(
                for: conversationKey,
                limit: historyLimit
            ),
            authoredPrerecording: .init(
                prerecordingID: prerecording.prerecordingID,
                speakerID: prerecording.speaker,
                transcript: prerecording.transcript,
                alreadySpoken: true,
                generatedResponseMustContinueAfterIt: true
            )
        )
    }

    func appendCompletedScriptPoint(
        identity: TuringFlowIdentity,
        prerecording: TuringPrerecordingDescriptor,
        generatedSegments: [TuringSpeechSegment],
        conversationKey: String,
        skippedSegmentIndices: Set<Int>
    ) {
        var turns = turnsByConversationKey[conversationKey] ?? []

        let prTurn = TuringVoicePromptContext.Turn(
            turnID: "\(identity.flowInstanceID.uuidString).pr",
            scriptPointID: identity.scriptPointID,
            speakerID: prerecording.speaker,
            text: prerecording.transcript,
            source: .authoredPrerecording
        )
        appendIfAbsent(prTurn, to: &turns)

        for (index, segment) in generatedSegments.enumerated()
        where skippedSegmentIndices.contains(index) == false {
            let turn = TuringVoicePromptContext.Turn(
                turnID: "\(identity.flowInstanceID.uuidString).generated.\(index)",
                scriptPointID: identity.scriptPointID,
                speakerID: identity.characterID,
                text: segment.text,
                source: .generatedVoicePrompt
            )
            appendIfAbsent(turn, to: &turns)
        }

        turnsByConversationKey[conversationKey] = turns
    }

    func appendConversation(
        conversationKey: String,
        playerText: String,
        responseSpeakerID: String,
        responseSegments: [TuringSpeechSegment],
        conversationRunID: UUID
    ) {
        var turns = turnsByConversationKey[conversationKey] ?? []

        appendIfAbsent(
            .init(
                turnID: "\(conversationRunID.uuidString).player",
                scriptPointID: nil,
                speakerID: "rich",
                text: playerText,
                source: .playerDictation
            ),
            to: &turns
        )

        for (index, segment) in responseSegments.enumerated() {
            appendIfAbsent(
                .init(
                    turnID: "\(conversationRunID.uuidString).response.\(index)",
                    scriptPointID: nil,
                    speakerID: responseSpeakerID,
                    text: segment.text,
                    source: .generatedConversation
                ),
                to: &turns
            )
        }

        turnsByConversationKey[conversationKey] = turns
    }

    func clear(conversationKey: String) {
        turnsByConversationKey.removeValue(forKey: conversationKey)
    }

    func clearAll(reason: String) {
        turnsByConversationKey.removeAll(keepingCapacity: false)
        print("""
        [TuringFlow] dialogue history cleared
          reason: \(reason)
        """)
    }

    private func appendIfAbsent(
        _ turn: TuringVoicePromptContext.Turn,
        to turns: inout [TuringVoicePromptContext.Turn]
    ) {
        guard turns.contains(where: { $0.turnID == turn.turnID }) == false else {
            return
        }
        turns.append(turn)
    }
}

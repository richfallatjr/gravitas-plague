import CryptoKit
import Foundation

nonisolated struct TuringFlowIdentity: Sendable, Hashable {
    let flowInstanceID: UUID
    let scriptPointID: String
    let characterID: String
    let prerecordingID: String
    let voicePromptID: String
    let playbackRunID: String
    let interactionSurface: StoryInteractionSurfaceID
    let spokenPresentationContinuity: TuringSpokenPresentationContinuity?

    init(
        flowInstanceID: UUID = UUID(),
        scriptPointID: String,
        characterID: String,
        prerecordingID: String,
        voicePromptID: String,
        interactionSurface: StoryInteractionSurfaceID = .walkie,
        playbackRunID: String? = nil,
        spokenPresentationContinuity: TuringSpokenPresentationContinuity? = nil
    ) {
        self.flowInstanceID = flowInstanceID
        self.scriptPointID = scriptPointID
        self.characterID = characterID
        self.prerecordingID = prerecordingID
        self.voicePromptID = voicePromptID
        self.interactionSurface = interactionSurface
        self.spokenPresentationContinuity = spokenPresentationContinuity
        self.playbackRunID =
            playbackRunID ??
            "\(scriptPointID).\(flowInstanceID.uuidString)"
    }
}

nonisolated enum TuringFlowHash {
    static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map {
            String(format: "%02x", $0)
        }.joined()
    }
}

nonisolated enum TuringFlowLog {
    static func event(
        _ name: String,
        identity: TuringFlowIdentity,
        fields: [(String, String)] = []
    ) {
        let extra = fields.map {
            "  \($0.0): \($0.1)"
        }.joined(separator: "\n")

        print("""
        [TuringFlow] \(name)
          flowInstanceID: \(identity.flowInstanceID.uuidString)
          scriptPointID: \(identity.scriptPointID)
          characterID: \(identity.characterID)
          prerecordingID: \(identity.prerecordingID)
          voicePromptID: \(identity.voicePromptID)
          interactionSurface: \(identity.interactionSurface.rawValue)
          playbackRunID: \(identity.playbackRunID)\(extra.isEmpty ? "" : "\n\(extra)")
        """)
    }
}

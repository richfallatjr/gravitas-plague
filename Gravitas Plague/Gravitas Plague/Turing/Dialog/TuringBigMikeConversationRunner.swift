import Foundation

enum TuringBigMikeConversationRunner {
    static func run(
        playerDictation: String,
        seedStore: TuringConversationSeedStore = .shared,
        onSegmentZeroReady:
            (@MainActor @Sendable () -> Void)? = nil
    ) async -> TuringVoiceRunResult {
        await TuringFlowConversationRunner.run(
            request: TuringFlowConversationRequest(
                characterID:
                    TuringBigMikeVoiceIdentity
                        .characterID,
                outputRoute: .walkieSpatial,
                conversationKey:
                    TuringDialogueThreadIdentity
                        .bigMikeRich,
                playerDictation:
                    playerDictation,
                episodeStateForWordsOnly:
                    "Rich and Big Mike are in an active early-outbreak radio conversation. Big Mike is nearby, protective, tired, uncertain about the Plague, and trying to keep Rich alive.",
                emotion:
                    "protective, grounded, tired, alert",
                voiceVariantID: nil
            ),
            seedStore: seedStore,
            historyStore: .shared,
            onSegmentZeroReady:
                onSegmentZeroReady
        )
    }
}

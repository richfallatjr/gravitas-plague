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
                    playerDictation
            ),
            seedStore: seedStore,
            onSegmentZeroReady:
                onSegmentZeroReady
        )
    }
}

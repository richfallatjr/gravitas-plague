import Foundation

enum TuringBigMikeConversationRunner {
    static func run(
        playerDictation: String,
        interactionLease: StoryInteractionLease? = nil,
        inputStore: TuringConversationInputStore = .shared,
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
                interactionLease:
                    interactionLease
            ),
            inputStore: inputStore,
            onSegmentZeroReady:
                onSegmentZeroReady
        )
    }
}

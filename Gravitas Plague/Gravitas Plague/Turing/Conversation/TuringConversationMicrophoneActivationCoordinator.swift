import Foundation

actor TuringConversationMicrophoneActivationCoordinator {
    static let shared = TuringConversationMicrophoneActivationCoordinator()

    private let arbiter = StoryInteractionArbiter.shared

    func authoredMediaStarted(
        entry: TuringLiveConversationCatalog.Entry,
        item: TuringAuthoredMediaItem,
        descriptor: TuringFlowDescriptor,
        parentSequenceID: UUID,
        identity: TuringFlowIdentity,
        expectedMicrophoneGeneration: UInt64
    ) async throws -> TuringLiveConversationSeed {
        let seed = try TuringLiveConversationSeedResolver().resolve(
            entry: entry,
            item: item,
            descriptor: descriptor,
            parentSequenceID: parentSequenceID,
            identity: identity,
            microphoneGeneration: expectedMicrophoneGeneration
        )
        let slot = TuringLatchedMicrophoneSlot(
            slotID: UUID(),
            generation: seed.microphoneGeneration,
            episodeID: seed.episodeID,
            segmentID: seed.segmentID,
            surface: seed.interactionSurface,
            activationMomentID: seed.sourceMomentID,
            targetCharacterID: seed.targetContext.targetCharacterID,
            seed: seed
        )
        try await arbiter.latchConversationMicrophone(
            slot: slot,
            expectedGeneration: expectedMicrophoneGeneration,
            reason: "actualPRStart.\(entry.momentID)"
        )
        print(
            "[TuringLiveConversation] microphone activated " +
                "episodeID=\(seed.episodeID.rawValue) " +
                "segmentID=\(seed.segmentID) " +
                "momentID=\(seed.sourceMomentID) " +
                "surface=\(seed.interactionSurface.rawValue) " +
                "speaker=\(seed.immediateDeviceContext.speakerCharacterID.rawValue) " +
                "target=\(seed.targetContext.targetCharacterID.rawValue) " +
                "contextPosition=\(seed.targetContext.selectionPosition.rawValue) " +
                "generation=\(seed.microphoneGeneration)"
        )
        return seed
    }
}

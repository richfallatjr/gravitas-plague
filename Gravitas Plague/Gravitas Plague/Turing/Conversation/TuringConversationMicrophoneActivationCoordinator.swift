import Foundation

nonisolated enum TuringPrerecordingPreFillerMicrophoneContext:
    Sendable,
    Equatable
{
    case previousConversationVoice(seedID: UUID)
    case currentPromptVoiceFallback
}

nonisolated enum TuringPrerecordingPreFillerMicrophonePolicy {
    static func context(
        retainedSeeds: TuringLiveConversationSeedRegistrySnapshot,
        upcomingSurface: StoryInteractionSurfaceID
    ) -> TuringPrerecordingPreFillerMicrophoneContext {
        guard let retained = retainedSeeds.seedsBySurface[upcomingSurface] else {
            return .currentPromptVoiceFallback
        }
        return .previousConversationVoice(seedID: retained.seedID)
    }
}

nonisolated struct TuringConversationMicrophoneActivationResult:
    Sendable,
    Equatable
{
    let seed: TuringLiveConversationSeed
    let eligibleSeeds: TuringLiveConversationSeedRegistrySnapshot
}

actor TuringConversationMicrophoneActivationCoordinator {
    static let shared = TuringConversationMicrophoneActivationCoordinator()

    private let arbiter = StoryInteractionArbiter.shared

    func authoredMediaStarted(
        entry: TuringLiveConversationCatalog.Entry,
        item: TuringAuthoredMediaItem,
        descriptor: TuringFlowDescriptor,
        parentSequenceID: UUID,
        identity: TuringFlowIdentity,
        expectedMicrophoneGeneration: UInt64,
        parentLease: StoryInteractionLease,
        liveSessionID: UUID,
        livePresentationGeneration: UInt64,
        activationPhase: String
    ) async throws -> TuringConversationMicrophoneActivationResult {
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
        let eligibleSeeds = try await arbiter.activateConversationMicrophone(
            slot: slot,
            expectedGeneration: expectedMicrophoneGeneration,
            parentLease: parentLease,
            sessionID: liveSessionID,
            presentationGeneration: livePresentationGeneration,
            authoredActivitySurface: seed.interactionSurface,
            reason: "\(activationPhase).\(entry.momentID)"
        )
        print(
            "[TuringLiveConversation] microphone activated " +
                "phase=\(activationPhase) " +
                "episodeID=\(seed.episodeID.rawValue) " +
                "segmentID=\(seed.segmentID) " +
                "momentID=\(seed.sourceMomentID) " +
                "surface=\(seed.interactionSurface.rawValue) " +
                "speaker=\(seed.immediateDeviceContext.speakerCharacterID.rawValue) " +
                "target=\(seed.targetContext.targetCharacterID.rawValue) " +
                "contextPosition=\(seed.targetContext.selectionPosition.rawValue) " +
                "selectedMomentID=\(seed.targetContext.selectedMomentID) " +
                "voicePromptID=\(seed.voicePromptID) " +
                "generation=\(seed.microphoneGeneration)"
        )
        return TuringConversationMicrophoneActivationResult(
            seed: seed,
            eligibleSeeds: eligibleSeeds
        )
    }
}

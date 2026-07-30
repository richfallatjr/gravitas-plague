import Foundation

@MainActor
final class TuringCatEye81HamReceiverFlowRoute:
    TuringFlowRouteRuntime
{
    let outputRoute =
        TuringVoiceOutputContext
            .hamReceiverSpatial

    let startsGeneratedComputeDuringPrerecordingLeadIn =
        false

    private let receiverBed:
        any TuringHamReceiverBedControlling
    private let tuningLoops:
        any TuringGeneratedGapBridge

    convenience init() {
        self.init(
            receiverBed:
                TuringHamReceiverBedActor.shared,
            tuningLoops:
                TuringRandomTuningLoopActor
                    .hamReceiver
        )
    }

    init(
        receiverBed:
            any TuringHamReceiverBedControlling,
        tuningLoops:
            any TuringGeneratedGapBridge
    ) {
        self.receiverBed = receiverBed
        self.tuningLoops = tuningLoops
    }

    func validate(
        descriptor: TuringFlowDescriptor,
        character:
            TuringCharacterRuntimeDefinition
    ) throws {
        guard character.characterID ==
                TuringCatEye81VoiceIdentity
                    .characterID,
              character.supports(outputRoute) else {
            throw TuringRuntimeError.invalidConfig(
                "hamReceiverSpatial requires the CatEye81 runtime."
            )
        }
        guard descriptor.transmission
                .outputRoute == outputRoute,
              descriptor.transmission
                .effectiveInteractionSurface ==
                .hamReceiver else {
            throw TuringRuntimeError.invalidConfig(
                "CatEye81 receiver output requires the hamReceiver interaction surface."
            )
        }
        guard descriptor.transmission.commSFX
                .openBeforePrerecording == false,
              descriptor.transmission.commSFX
                .sendAfterGenerated == false,
              descriptor.transmission
                .fixedLeadInSeconds == nil else {
            throw TuringRuntimeError.invalidConfig(
                "Ham receiver cannot use walkie communication effects."
            )
        }
    }

    func makePlayback(
        descriptor: TuringFlowDescriptor,
        character:
            TuringCharacterRuntimeDefinition,
        identity: TuringFlowIdentity
    ) throws -> any TuringFlowPlaybackControlling {
        let endpoint =
            try TuringHamReceiverAudioRoute
                .requireActiveEndpoint()
        var policy =
            TuringFlowPlaybackPolicyBuilder.make(
                descriptor: descriptor,
                character: character,
                voiceRoute:
                    .hamReceiverSpatial
            )
        policy.externalGeneratedGapBridge =
            tuningLoops
        policy.prerecordingPrecedesGenerated =
            isInitialTransmission(descriptor)
        policy.fillerDirectoryCandidates = []
        policy.fillerExtensions = []
        return TuringStoryWalkiePlaybackCoordinator(
            policy: policy,
            rootURL:
                TuringFlowPlaybackPolicyBuilder
                    .rootURL(
                        identity: identity
                    ),
            endpoint: endpoint
        )
    }

    func runFixedLeadInIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async {
    }

    func playOpenIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        guard isInitialTransmission(
            descriptor
        ) else {
            return
        }
        try await receiverBed.beginSession(
            ownerID: identity.playbackRunID
        )
        await tuningLoops.beginGap(
            ownerID: identity.playbackRunID,
            waitingForSegmentIndex: 0,
            reason:
                "initialFoundationPreparation"
        )
    }

    func beginPrerecordingLeadInIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        guard isInitialTransmission(
            descriptor
        ) else {
            return
        }
        await tuningLoops.endGap(
            ownerID: identity.playbackRunID,
            reason:
                "foundationCompletedBeforePrerecording"
        )
    }

    func playSendIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
    }

    func finish(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity,
        succeeded: Bool
    ) async {
        await tuningLoops.endGap(
            ownerID: identity.playbackRunID,
            reason:
                "hamReceiverFlowFinished.succeeded.\(succeeded)"
        )
        await receiverBed.endSession(
            ownerID: identity.playbackRunID,
            reason:
                succeeded
                    ? "hamReceiverFlowFinished"
                    : "hamReceiverFlowFailed"
        )
    }

    private func isInitialTransmission(
        _ descriptor: TuringFlowDescriptor
    ) -> Bool {
        descriptor.transmission.prerecordingID !=
            "none"
    }
}

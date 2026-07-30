import Foundation

@MainActor
final class TuringBroadcasterCrankRadioFlowRoute:
    TuringFlowRouteRuntime
{
    let outputRoute =
        TuringVoiceOutputContext.crankRadioSpatial
    let startsGeneratedComputeDuringPrerecordingLeadIn =
        true

    private let radioBed:
        any TuringRollingBenchRadioBedControlling
    private let tuningLoops:
        any TuringGeneratedGapBridge
    private var cueHandlesByPlaybackRunID:
        [String: TuringAudioPlaybackHandle] = [:]

    convenience init() {
        self.init(
            radioBed:
                TuringRollingBenchRadioBedActor.shared,
            tuningLoops:
                TuringCrankRadioTuningLoopActor.shared
        )
    }

    init(
        radioBed:
            any TuringRollingBenchRadioBedControlling,
        tuningLoops:
            any TuringGeneratedGapBridge
    ) {
        self.radioBed = radioBed
        self.tuningLoops = tuningLoops
    }

    func validate(
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition
    ) throws {
        guard character.characterID ==
                TuringBroadcasterVoiceIdentity.characterID,
              character.supports(outputRoute) else {
            throw TuringRuntimeError.invalidConfig(
                "crankRadioSpatial requires the Broadcaster runtime."
            )
        }
        guard descriptor.transmission.outputRoute ==
                outputRoute,
              descriptor.transmission
                .effectiveInteractionSurface ==
                .crankRadio else {
            throw TuringRuntimeError.invalidConfig(
                "Broadcaster crank-radio output requires the crankRadio interaction surface."
            )
        }
        guard descriptor.transmission.commSFX
                .openBeforePrerecording == false,
              descriptor.transmission.commSFX
                .sendAfterGenerated == false,
              descriptor.transmission.fixedLeadInSeconds ==
                nil else {
            throw TuringRuntimeError.invalidConfig(
                "Broadcaster crank-radio output cannot contain walkie communication effects."
            )
        }
    }

    func makePlayback(
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition,
        identity: TuringFlowIdentity
    ) throws -> any TuringFlowPlaybackControlling {
        let endpoint =
            try TuringRollingBenchAudioRoute
                .requireActiveEndpoint()
        var policy =
            TuringFlowPlaybackPolicyBuilder.make(
                descriptor: descriptor,
                character: character,
                voiceRoute: .crankRadioSpatial
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
                TuringFlowPlaybackPolicyBuilder.rootURL(
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
        guard isInitialTransmission(descriptor) else {
            return
        }
        try await radioBed.beginSession(
            ownerID: identity.playbackRunID
        )
        await tuningLoops.beginGap(
            ownerID: identity.playbackRunID,
            waitingForSegmentIndex: 0,
            reason: "initialFoundationPreparation"
        )
    }

    func beginPrerecordingLeadInIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        guard isInitialTransmission(descriptor) else {
            return
        }
        await tuningLoops.endGap(
            ownerID: identity.playbackRunID,
            reason:
                "foundationCompletedBeforeEmergencyCue"
        )
        let handle =
            try await radioBed.startEmergencyCue(
                ownerID: identity.playbackRunID
            )
        cueHandlesByPlaybackRunID[
            identity.playbackRunID
        ] = handle
        print("""
        [TuringBroadcasterFlow] generated compute released by alarm
          playbackRunID: \(identity.playbackRunID)
          cueHandleID: \(handle.id.uuidString)
          prerecordingQueued: false
        """)
    }

    func waitForPrerecordingLeadInCompletionIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        guard isInitialTransmission(descriptor) else {
            return
        }
        guard let handle =
                cueHandlesByPlaybackRunID[
                    identity.playbackRunID
                ] else {
            throw TuringRuntimeError.invalidConfig(
                "Broadcaster alarm did not start before PR playback."
            )
        }
        defer {
            cueHandlesByPlaybackRunID[
                identity.playbackRunID
            ] = nil
        }
        try await radioBed.waitForEmergencyCueCompletion(
            handle,
            ownerID: identity.playbackRunID
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
        cueHandlesByPlaybackRunID[
            identity.playbackRunID
        ] = nil
        await tuningLoops.endGap(
            ownerID: identity.playbackRunID,
            reason:
                "broadcasterFlowFinished.succeeded.\(succeeded)"
        )
        guard isInitialTransmission(descriptor) else {
            return
        }
        await radioBed.endSession(
            ownerID: identity.playbackRunID,
            reason:
                succeeded
                    ? "broadcasterPromptVoiceFinished"
                    : "broadcasterPromptVoiceFailed"
        )
    }

    private func isInitialTransmission(
        _ descriptor: TuringFlowDescriptor
    ) -> Bool {
        descriptor.transmission.prerecordingID !=
            "none"
    }
}

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
    private static let finalPSAScriptPointID =
        "chapter02.crankRadio.broadcaster.gravitasPSA.003"

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
        if isFinalPSA(descriptor) {
            _ = await Chapter02BattleMusicActor.shared.duck(
                ownerID: chapter02BattleMusicOwnerID(identity)
            )
        }
        let handle: TuringAudioPlaybackHandle
        do {
            if isFinalPSA(descriptor) {
                handle = try await radioBed.startAuthoredCue(
                    ownerID: identity.playbackRunID,
                    resourceName: "gravitas-opening-jingle",
                    fileExtension: "mp3",
                    label: "chapter02GravitasOpeningJingle"
                )
            } else {
                handle = try await radioBed.startEmergencyCue(
                    ownerID: identity.playbackRunID
                )
            }
        } catch {
            if isFinalPSA(descriptor) {
                await Chapter02BattleMusicActor.shared.restore(
                    ownerID: chapter02BattleMusicOwnerID(identity)
                )
            }
            throw error
        }
        cueHandlesByPlaybackRunID[
            identity.playbackRunID
        ] = handle
        print("""
        [TuringBroadcasterFlow] generated compute released by authored cue
          playbackRunID: \(identity.playbackRunID)
          cueHandleID: \(handle.id.uuidString)
          cueKind: \(isFinalPSA(descriptor) ? "openingJingle" : "emergencyDataBurst")
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
    ) async throws {
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
        if succeeded && isFinalPSA(descriptor) {
            do {
                let closingHandle = try await radioBed.startAuthoredCue(
                    ownerID: identity.playbackRunID,
                    resourceName: "gravitas-closing-bumper",
                    fileExtension: "mp3",
                    label: "chapter02GravitasClosingBumper"
                )
                print(
                    "[TuringBroadcasterFlow] closing bumper started " +
                        "playbackRunID=\(identity.playbackRunID) " +
                        "handleID=\(closingHandle.id.uuidString)"
                )
                try await radioBed.waitForEmergencyCueCompletion(
                    closingHandle,
                    ownerID: identity.playbackRunID
                )
                print(
                    "[TuringBroadcasterFlow] closing bumper actual completion " +
                        "playbackRunID=\(identity.playbackRunID)"
                )
            } catch {
                await radioBed.endSession(
                    ownerID: identity.playbackRunID,
                    reason: "chapter02ClosingBumperFailed"
                )
                await Chapter02BattleMusicActor.shared.restore(
                    ownerID: chapter02BattleMusicOwnerID(identity)
                )
                throw error
            }
        }
        await radioBed.endSession(
            ownerID: identity.playbackRunID,
            reason:
                succeeded
                    ? "broadcasterPromptVoiceFinished"
                    : "broadcasterPromptVoiceFailed"
        )
        if isFinalPSA(descriptor) {
            await Chapter02BattleMusicActor.shared.restore(
                ownerID: chapter02BattleMusicOwnerID(identity)
            )
        }
    }

    private func isInitialTransmission(
        _ descriptor: TuringFlowDescriptor
    ) -> Bool {
        descriptor.transmission.prerecordingID !=
            "none"
    }

    private func isFinalPSA(
        _ descriptor: TuringFlowDescriptor
    ) -> Bool {
        descriptor.scriptPointID == Self.finalPSAScriptPointID
    }

    private func chapter02BattleMusicOwnerID(
        _ identity: TuringFlowIdentity
    ) -> String {
        "chapter02.crankPSA.\(identity.playbackRunID)"
    }
}

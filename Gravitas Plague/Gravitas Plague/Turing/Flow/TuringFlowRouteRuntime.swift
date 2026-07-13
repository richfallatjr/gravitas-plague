import Foundation

@MainActor
protocol TuringFlowPlaybackControlling: AnyObject, Sendable {
    func configureFlowIdentity(
        _ identity: TuringFlowIdentity
    )

    func beginRun(
        runID: String,
        expectedSegmentCount: Int?
    ) async

    func enqueuePrerecording(
        id: String,
        fileURL: URL
    ) async

    func setExpectedGeneratedSegmentCount(
        _ count: Int
    ) async

    func qwenComputeStarted(
        segmentIndex: Int
    ) async

    func qwenComputeFinished(
        segmentIndex: Int,
        audio: TuringComputeGapGeneratedAudio
    ) async

    func qwenComputeSkipped(
        segmentIndex: Int,
        reason: String
    ) async

    func qwenComputeAllFinished() async

    func qwenComputeFailed(
        expectedSegmentCount: Int,
        reason: String
    ) async

    func waitUntilPlaybackFinished() async
    func completedGeneratedSegmentCount() -> Int
    func runCancelled(reason: String) async
}

extension TuringStoryWalkiePlaybackCoordinator:
    TuringFlowPlaybackControlling
{
}

@MainActor
protocol TuringFlowRouteRuntime: AnyObject, Sendable {
    var outputRoute: TuringVoiceOutputContext { get }

    func validate(
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition
    ) throws

    func makePlayback(
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition,
        identity: TuringFlowIdentity
    ) throws -> any TuringFlowPlaybackControlling

    func runFixedLeadInIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async

    func playOpenIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws

    func playSendIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws

    func finish(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity,
        succeeded: Bool
    ) async
}


extension TuringFlowRouteRuntime {
    func makeGeneratedOnlyPlayback(
        character: TuringCharacterRuntimeDefinition,
        conversationRunID: UUID
    ) throws -> (
        playback: any TuringFlowPlaybackControlling,
        identity: TuringFlowIdentity,
        descriptor: TuringFlowDescriptor
    ) {
        let scriptPointID =
            "conversation.\(conversationRunID.uuidString)"
        let descriptor = TuringFlowDescriptor(
            schemaVersion: 2,
            scriptPointID: scriptPointID,
            trigger: .init(
                kind: .manualDebug,
                delaySeconds: 0
            ),
            transmission: .init(
                prerecordingID: "none",
                voicePromptID: "conversationPrompt",
                characterID: character.characterID,
                conversationKey: "conversation",
                outputRoute: outputRoute,
                computeStart: .afterPriorPoint,
                fillerMode: .onePrerollThenComputeGap,
                commSFX: .init(
                    openBeforePrerecording: false,
                    sendAfterGenerated: false,
                    sendingLeadInAfterGeneratedSeconds: nil
                ),
                fixedLeadInSeconds: nil
            ),
            progression: .init(
                nextScriptPointID: nil,
                automaticAdvance: false,
                interactionGateAfterCompletion: .microphone
            )
        )
        let identity = TuringFlowIdentity(
            flowInstanceID: conversationRunID,
            scriptPointID: scriptPointID,
            characterID: character.characterID,
            prerecordingID: "none",
            voicePromptID: "conversationPrompt"
        )

        return (
            try makePlayback(
                descriptor: descriptor,
                character: character,
                identity: identity
            ),
            identity,
            descriptor
        )
    }
}


protocol TuringFlowRouteResolving: Sendable {
    func require(
        _ outputRoute: TuringVoiceOutputContext
    ) async throws -> any TuringFlowRouteRuntime
}

struct TuringDefaultFlowRouteResolver:
    TuringFlowRouteResolving,
    Sendable
{
    func require(
        _ outputRoute: TuringVoiceOutputContext
    ) async throws -> any TuringFlowRouteRuntime {
        try await TuringFlowRouteRegistry.shared
            .require(outputRoute)
    }
}

@MainActor
final class TuringFlowRouteRegistry {
    static let shared = TuringFlowRouteRegistry()

    private var routes:
        [String: any TuringFlowRouteRuntime] = [:]

    init(
        builtIns: [any TuringFlowRouteRuntime]? = nil
    ) {
        let resolvedBuiltIns = builtIns ?? [
            TuringBigMikeWalkieFlowRoute(),
            TuringRichWalkieFlowRoute(),
            TuringRichRoomFlowRoute()
        ]
        for route in resolvedBuiltIns {
            routes[route.outputRoute.rawValue] = route
        }
    }

    func register(
        _ route: any TuringFlowRouteRuntime
    ) throws {
        guard routes[route.outputRoute.rawValue] == nil else {
            throw TuringRuntimeError.invalidConfig(
                "Duplicate Turing Flow output route: \(route.outputRoute.rawValue)."
            )
        }
        routes[route.outputRoute.rawValue] = route
    }

    func require(
        _ outputRoute: TuringVoiceOutputContext
    ) throws -> any TuringFlowRouteRuntime {
        guard let route = routes[outputRoute.rawValue] else {
            throw TuringRuntimeError.invalidConfig(
                "No Turing Flow route runtime for \(outputRoute.rawValue)."
            )
        }
        return route
    }
}

@MainActor
private enum TuringFlowPlaybackPolicyBuilder {
    static func make(
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition,
        voiceRoute: TuringStoryWalkiePlaybackCoordinator.VoiceRoute
    ) -> TuringStoryWalkiePlaybackCoordinator.Policy {
        var policy = TuringStoryWalkiePlaybackCoordinator.Policy()

        switch descriptor.transmission.fillerMode {
        case .onePrerollThenComputeGap:
            policy.firstSegmentPrerollFillerCount = 1
            policy.chainFillerFromPrerecordingToFirstGenerated = false
            policy.chainFillerWhileComputeWithoutSpeech = true

        case .continuousFromPrerecordingToGenerated:
            policy.firstSegmentPrerollFillerCount = 0
            policy.chainFillerFromPrerecordingToFirstGenerated = true
            policy.chainFillerWhileComputeWithoutSpeech = true

        case .none:
            policy.firstSegmentPrerollFillerCount = 0
            policy.chainFillerFromPrerecordingToFirstGenerated = false
            policy.chainFillerWhileComputeWithoutSpeech = false
        }

        policy.voiceRoute = voiceRoute
        policy.outputProcessingPolicy =
            character.outputProcessingPolicy
        policy.generatedGainDB =
            character.audio.generatedGainDB
        policy.prerecordingGainDB =
            character.audio.prerecordingGainDB
        policy.fillerGainDB =
            character.audio.fillerGainDB
        policy.fillerDirectoryCandidates =
            character.audio.fillerDirectoryCandidates
        policy.fillerExtensions =
            Set(character.audio.fillerExtensions)

        return policy
    }

    static func rootURL(
        identity: TuringFlowIdentity
    ) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TuringFlowPlayback",
                isDirectory: true
            )
            .appendingPathComponent(
                identity.flowInstanceID.uuidString,
                isDirectory: true
            )
    }
}

@MainActor
final class TuringBigMikeWalkieFlowRoute:
    TuringFlowRouteRuntime
{
    let outputRoute = TuringVoiceOutputContext.walkieSpatial

    func validate(
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition
    ) throws {
        guard character.supports(outputRoute) else {
            throw TuringRuntimeError.invalidConfig(
                "\(character.characterID) does not support \(outputRoute.rawValue)."
            )
        }
    }

    func makePlayback(
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition,
        identity: TuringFlowIdentity
    ) throws -> any TuringFlowPlaybackControlling {
        var policy = TuringFlowPlaybackPolicyBuilder.make(
            descriptor: descriptor,
            character: character,
            voiceRoute: .walkieSpatial
        )
        policy.stopSendingStaticBeforeGeneratedSegmentZero = true

        return TuringStoryWalkiePlaybackCoordinator(
            policy: policy,
            rootURL:
                TuringFlowPlaybackPolicyBuilder.rootURL(
                    identity: identity
                )
        )
    }

    func runFixedLeadInIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async {
        guard let seconds =
            descriptor.transmission.fixedLeadInSeconds,
              seconds > 0 else {
            return
        }

        await TuringWalkieCommsFXController.shared
            .runFixedResponseLeadInAfterExternalSend(
                reason:
                    "flow.\(identity.flowInstanceID.uuidString).leadIn",
                durationSeconds: seconds
            )
    }

    func playOpenIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        await TuringWalkieCommsFXController.shared
            .startAmbientWalkieStatic(
                reason:
                    "flow.\(identity.flowInstanceID.uuidString).bigMike"
            )

        guard descriptor.transmission.commSFX
            .openBeforePrerecording else {
            return
        }

        try await TuringWalkieCommsFXController.shared
            .playScriptedOpenComm(
                reason:
                    "flow.\(identity.flowInstanceID.uuidString).open"
            )
    }

    func playSendIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        guard descriptor.transmission.commSFX
            .sendAfterGenerated else {
            return
        }

        try await TuringWalkieCommsFXController.shared
            .playScriptedSendComm(
                reason:
                    "flow.\(identity.flowInstanceID.uuidString).send"
            )
    }

    func finish(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity,
        succeeded: Bool
    ) async {
        await TuringWalkieCommsFXController.shared
            .stopSendingLeadIn(
                reason:
                    "flow.\(identity.flowInstanceID.uuidString).finished"
            )
        await TuringWalkieCommsFXController.shared
            .stopAmbientWalkieStatic(
                reason:
                    "flow.\(identity.flowInstanceID.uuidString).finished"
            )
    }
}

@MainActor
final class TuringRichWalkieFlowRoute:
    TuringFlowRouteRuntime
{
    let outputRoute =
        TuringVoiceOutputContext.walkieOutgoingGlobal

    func validate(
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition
    ) throws {
        guard character.characterID ==
                TuringRichVoiceIdentity.characterID,
              character.supports(outputRoute) else {
            throw TuringRuntimeError.invalidConfig(
                "walkieOutgoingGlobal requires the Rich player runtime."
            )
        }
    }

    func makePlayback(
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition,
        identity: TuringFlowIdentity
    ) throws -> any TuringFlowPlaybackControlling {
        let policy = TuringFlowPlaybackPolicyBuilder.make(
            descriptor: descriptor,
            character: character,
            voiceRoute: .playerHeadTracked
        )

        return TuringStoryWalkiePlaybackCoordinator(
            policy: policy,
            rootURL:
                TuringFlowPlaybackPolicyBuilder.rootURL(
                    identity: identity
                ),
            globalPlayer:
                TuringRichRoutedOneShotClipPlayer()
        )
    }

    func runFixedLeadInIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async {
        // Rich outgoing speech has no pre-PR response lead-in.
    }

    func playOpenIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        guard descriptor.transmission.commSFX
            .openBeforePrerecording else {
            return
        }

        // Deliberately distinct Rich walkie treatment. Rich voice stays at the
        // player; the authored activation chirp comes from the walkie prop.
        try await TuringWalkieCommsFXController.shared
            .playScriptedOpenComm(
                reason:
                    "flow.\(identity.flowInstanceID.uuidString).richOpen"
            )
    }

    func playSendIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        guard descriptor.transmission.commSFX
            .sendAfterGenerated else {
            return
        }

        try await TuringWalkieCommsFXController.shared
            .playScriptedSendComm(
                reason:
                    "flow.\(identity.flowInstanceID.uuidString).richSend"
            )

        if let seconds = descriptor.transmission.commSFX
            .sendingLeadInAfterGeneratedSeconds,
           seconds > 0 {
            await TuringWalkieCommsFXController.shared
                .runFixedResponseLeadInAfterExternalSend(
                    reason:
                        "flow.\(identity.flowInstanceID.uuidString).richPostSend",
                    durationSeconds: seconds
                )
        }
    }

    func finish(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity,
        succeeded: Bool
    ) async {
        if succeeded == false {
            await TuringWalkieCommsFXController.shared
                .stopAll(
                    reason:
                        "flow.\(identity.flowInstanceID.uuidString).richFailed"
                )
        }
    }
}

@MainActor
final class TuringRichRoomFlowRoute:
    TuringFlowRouteRuntime
{
    let outputRoute = TuringVoiceOutputContext.roomGlobal

    func validate(
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition
    ) throws {
        guard character.characterID ==
                TuringRichVoiceIdentity.characterID,
              character.supports(outputRoute) else {
            throw TuringRuntimeError.invalidConfig(
                "roomGlobal requires a character runtime that supports roomGlobal."
            )
        }

        guard descriptor.transmission.commSFX
            .openBeforePrerecording == false,
              descriptor.transmission.commSFX
            .sendAfterGenerated == false,
              descriptor.transmission.fixedLeadInSeconds == nil else {
            throw TuringRuntimeError.invalidConfig(
                "roomGlobal cannot contain walkie comm effects."
            )
        }
    }

    func makePlayback(
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition,
        identity: TuringFlowIdentity
    ) throws -> any TuringFlowPlaybackControlling {
        let policy = TuringFlowPlaybackPolicyBuilder.make(
            descriptor: descriptor,
            character: character,
            voiceRoute: .playerHeadTracked
        )

        return TuringStoryWalkiePlaybackCoordinator(
            policy: policy,
            rootURL:
                TuringFlowPlaybackPolicyBuilder.rootURL(
                    identity: identity
                ),
            globalPlayer:
                TuringRichRoutedOneShotClipPlayer()
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
    }
}

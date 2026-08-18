import Foundation

actor TuringFlowMediaCueCoordinator {
    static let shared = TuringFlowMediaCueCoordinator()

    private struct ActiveCue {
        let token: StoryMemoryMusicActor.Token
        let descriptor: TuringFlowBackgroundMusicDescriptor
        let priorAftermathWasPlaying: Bool
    }

    private var activeByFlowID: [UUID: ActiveCue] = [:]
    private var orientationFlowByTokenID: [UUID: UUID] = [:]
    private var liveGapFlowByTokenID: [UUID: UUID] = [:]
    private var deferredStopReasonByFlowID: [UUID: String] = [:]

    func startIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        guard let music = descriptor.transmission.backgroundMusic else {
            return
        }
        try await startIfNeeded(music: music, identity: identity)
    }

    private func startIfNeeded(
        music: TuringFlowBackgroundMusicDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        guard activeByFlowID[identity.flowInstanceID] == nil else { return }

        let fileURL = try TuringResourceLoader.resourceURL(
            resourcePath: music.resourcePath
        )
        let priorAftermathWasPlaying =
            await StoryAftermathMusicActor.shared
                .duckForMemoryCue(
                    fadeDuration: music.fadeInSeconds
                )
        let token = try await StoryMemoryMusicActor.shared.start(
            descriptor: music,
            fileURL: fileURL,
            flowInstanceID: identity.flowInstanceID
        )
        activeByFlowID[identity.flowInstanceID] = ActiveCue(
            token: token,
            descriptor: music,
            priorAftermathWasPlaying: priorAftermathWasPlaying
        )
        if identity.interactionSurface == .dadFrame {
            print("""
            [TuringDadPhotoMusic] started
              resource: \(fileURL.lastPathComponent)
              gainDB: \(music.gainDB)
              loops: \(music.loops)
              flowInstanceID: \(identity.flowInstanceID.uuidString)
            """)
        }
    }

    func stopIfNeeded(
        identity: TuringFlowIdentity,
        reason: String
    ) async {
        if orientationFlowByTokenID.values.contains(identity.flowInstanceID) ||
            liveGapFlowByTokenID.values.contains(identity.flowInstanceID) {
            deferredStopReasonByFlowID[identity.flowInstanceID] = reason
            return
        }
        guard let active = activeByFlowID.removeValue(
            forKey: identity.flowInstanceID
        ) else {
            return
        }
        await StoryMemoryMusicActor.shared.stop(
            token: active.token,
            fadeDuration: active.descriptor.fadeOutSeconds,
            reason: reason
        )
        if active.priorAftermathWasPlaying {
            await StoryAftermathMusicActor.shared
                .restoreAfterMemoryCue(
                    fadeDuration:
                        active.descriptor.fadeOutSeconds
                )
        }
        if identity.interactionSurface == .dadFrame {
            print("""
            [TuringDadPhotoMusic] stopped
              boundary: \(reason)
              priorStoryMusicRestored: \(active.priorAftermathWasPlaying)
              flowInstanceID: \(identity.flowInstanceID.uuidString)
            """)
        }
    }

    func retainForLiveConversationGap(
        music: TuringFlowBackgroundMusicDescriptor?,
        identity: TuringFlowIdentity
    ) async throws -> StoryMemoryMusicLiveGapToken {
        if activeByFlowID[identity.flowInstanceID] == nil {
            guard let music else {
                throw TuringRuntimeError.invalidConfig(
                    "Dad-photo live conversation has no exact background-music descriptor."
                )
            }
            try await startIfNeeded(music: music, identity: identity)
        }
        guard let active = activeByFlowID[identity.flowInstanceID] else {
            throw TuringRuntimeError.invalidConfig(
                "Dad-photo live conversation could not retain its memory score."
            )
        }
        let token = StoryMemoryMusicLiveGapToken(
            id: UUID(),
            flowInstanceID: identity.flowInstanceID,
            memoryMusicToken: active.token
        )
        liveGapFlowByTokenID[token.id] = token.flowInstanceID
        return token
    }

    func releaseLiveConversationGap(
        token: StoryMemoryMusicLiveGapToken,
        reason: String
    ) async {
        guard liveGapFlowByTokenID.removeValue(forKey: token.id) ==
                token.flowInstanceID,
              liveGapFlowByTokenID.values.contains(token.flowInstanceID) == false,
              orientationFlowByTokenID.values.contains(token.flowInstanceID) == false,
              let active = activeByFlowID.removeValue(
                forKey: token.flowInstanceID
              ) else {
            return
        }
        deferredStopReasonByFlowID.removeValue(forKey: token.flowInstanceID)
        await StoryMemoryMusicActor.shared.stop(
            token: active.token,
            fadeDuration: active.descriptor.fadeOutSeconds,
            reason: reason
        )
        if active.priorAftermathWasPlaying {
            await StoryAftermathMusicActor.shared.restoreAfterMemoryCue(
                fadeDuration: active.descriptor.fadeOutSeconds
            )
        }
        print(
            "[TuringDadPhotoMusic] live gap released boundary=\(reason) " +
                "flowInstanceID=\(token.flowInstanceID.uuidString)"
        )
    }


    func retainForPrerecordingOrientation(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity,
        mediaItemID: String
    ) async throws -> TuringFlowMediaCueOrientationToken {
        try await startIfNeeded(descriptor: descriptor, identity: identity)
        guard let active = activeByFlowID[identity.flowInstanceID] else {
            throw TuringRuntimeError.invalidConfig(
                "Dad-photo orientation requires its authored background music."
            )
        }
        let token = TuringFlowMediaCueOrientationToken(
            id: UUID(),
            flowInstanceID: identity.flowInstanceID,
            memoryMusicToken: active.token
        )
        orientationFlowByTokenID[token.id] = identity.flowInstanceID
        print("[TuringPROrientation] Dad score retained itemID=\(mediaItemID) token=\(token.id.uuidString)")
        return token
    }

    func releasePrerecordingOrientation(
        token: TuringFlowMediaCueOrientationToken,
        reason: String
    ) async {
        guard orientationFlowByTokenID.removeValue(forKey: token.id) ==
                token.flowInstanceID else {
            return
        }
        guard orientationFlowByTokenID.values.contains(token.flowInstanceID) == false,
              liveGapFlowByTokenID.values.contains(token.flowInstanceID) == false,
              let deferredReason = deferredStopReasonByFlowID.removeValue(
                forKey: token.flowInstanceID
              ),
              let active = activeByFlowID.removeValue(
                forKey: token.flowInstanceID
              ) else {
            return
        }
        let stopReason = "\(deferredReason).\(reason)"
        await StoryMemoryMusicActor.shared.stop(
            token: active.token,
            fadeDuration: active.descriptor.fadeOutSeconds,
            reason: stopReason
        )
        if active.priorAftermathWasPlaying {
            await StoryAftermathMusicActor.shared.restoreAfterMemoryCue(
                fadeDuration: active.descriptor.fadeOutSeconds
            )
        }
        print(
            "[TuringDadPhotoMusic] stopped boundary=\(stopReason) " +
                "priorStoryMusicRestored=\(active.priorAftermathWasPlaying) " +
                "flowInstanceID=\(token.flowInstanceID.uuidString)"
        )
    }

    func stopAll(reason: String) async {
        let active = activeByFlowID.values
        activeByFlowID.removeAll(keepingCapacity: false)
        orientationFlowByTokenID.removeAll(keepingCapacity: false)
        liveGapFlowByTokenID.removeAll(keepingCapacity: false)
        deferredStopReasonByFlowID.removeAll(keepingCapacity: false)
        await StoryMemoryMusicActor.shared.stopAll(reason: reason)
        if active.contains(where: \.priorAftermathWasPlaying) {
            await StoryAftermathMusicActor.shared
                .restoreAfterMemoryCue(fadeDuration: 0.25)
        }
    }
}

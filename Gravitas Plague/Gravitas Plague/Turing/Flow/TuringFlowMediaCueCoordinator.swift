import Foundation

actor TuringFlowMediaCueCoordinator {
    static let shared = TuringFlowMediaCueCoordinator()

    private struct ActiveCue {
        let token: StoryMemoryMusicActor.Token
        let descriptor: TuringFlowBackgroundMusicDescriptor
        let priorAftermathWasPlaying: Bool
    }

    private var activeByFlowID: [UUID: ActiveCue] = [:]

    func startIfNeeded(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity
    ) async throws {
        guard let music = descriptor.transmission.backgroundMusic,
              activeByFlowID[identity.flowInstanceID] == nil else {
            return
        }

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

    func stopAll(reason: String) async {
        let active = activeByFlowID.values
        activeByFlowID.removeAll(keepingCapacity: false)
        await StoryMemoryMusicActor.shared.stopAll(reason: reason)
        if active.contains(where: \.priorAftermathWasPlaying) {
            await StoryAftermathMusicActor.shared
                .restoreAfterMemoryCue(fadeDuration: 0.25)
        }
    }
}

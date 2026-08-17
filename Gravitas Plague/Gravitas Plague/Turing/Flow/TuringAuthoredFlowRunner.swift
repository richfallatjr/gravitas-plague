import Foundation

actor TuringAuthoredFlowRunner {
    func run(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity,
        mediaPlan: TuringAuthoredMediaPlan,
        character: TuringCharacterRuntimeDefinition,
        route: any TuringFlowRouteRuntime
    ) async throws -> TuringFlowResult {
        for item in mediaPlan.items {
            guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
                throw TuringRuntimeError.invalidConfig(
                    "Missing authored media \(item.id) at \(item.fileURL.path)."
                )
            }
        }

        try await route.validate(descriptor: descriptor, character: character)
        await route.runFixedLeadInIfNeeded(descriptor: descriptor, identity: identity)
        try await route.playOpenIfNeeded(descriptor: descriptor, identity: identity)
        try await route.beginPrerecordingLeadInIfNeeded(
            descriptor: descriptor,
            identity: identity
        )
        try await route.waitForPrerecordingLeadInCompletionIfNeeded(
            descriptor: descriptor,
            identity: identity
        )

        let playback = try await route.makePlayback(
            descriptor: descriptor,
            character: character,
            identity: identity
        )
        await playback.configureFlowIdentity(identity)
        await playback.beginAuthoredRun(identity: identity)
        for item in mediaPlan.items {
            try await playback.enqueueAuthoredMedia(item)
        }
        await playback.sealAuthoredInput()
        try await playback.waitUntilAuthoredPlaybackFinished()

        try await route.playSendIfNeeded(descriptor: descriptor, identity: identity)
        try await route.finish(descriptor: descriptor, identity: identity, succeeded: true)

        return TuringFlowResult(
            outcome: .succeeded,
            identity: identity,
            expectedGeneratedSegmentCount: 0,
            completedGeneratedSegmentCount: 0,
            skippedGeneratedSegmentIndices: [],
            message: "Finished \(descriptor.scriptPointID)",
            experienceMode: .play,
            completionBasis: .authoredMediaPlaybackCompleted
        )
    }
}

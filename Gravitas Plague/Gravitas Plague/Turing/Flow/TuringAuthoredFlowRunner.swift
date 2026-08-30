import Foundation

actor TuringAuthoredFlowRunner {
    func run(
        descriptor: TuringFlowDescriptor,
        identity: TuringFlowIdentity,
        mediaPlan: TuringAuthoredMediaPlan,
        character: TuringCharacterRuntimeDefinition,
        route: any TuringFlowRouteRuntime,
        parentSequenceID: UUID,
        parentInteractionLease: StoryInteractionLease
    ) async throws -> TuringFlowResult {
        for item in mediaPlan.items {
            guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
                throw TuringRuntimeError.invalidConfig(
                    "Missing authored media \(item.id) at \(item.fileURL.path)."
                )
            }
        }

        try await route.validate(descriptor: descriptor, character: character)
        let playback = try await route.makePlayback(
            descriptor: descriptor,
            character: character,
            identity: identity
        )
        await playback.configureFlowIdentity(identity)
        await playback.beginAuthoredRun(identity: identity)
        let liveConversationCoordinator =
            await TuringLiveConversationSessionCoordinator.shared
        do {
            try await liveConversationCoordinator.attach(
                parentSequenceID: parentSequenceID,
                parentLease: parentInteractionLease,
                descriptor: descriptor,
                identity: identity,
                playback: playback
            )
            let preFillerPreparationTask: Task<Void, Never>?
            if let firstEligibleItem = mediaPlan.items.first(
                where: { $0.liveConversationCatalogEntry != nil }
            ) {
                // Portrait preparation and installation of the upcoming,
                // selectable PromptVoice microphone are speculative. They
                // must never sit on the authored playback path: the PR, route
                // lead-in, and orientation proceed while this task works.
                preFillerPreparationTask = Task { @MainActor in
                    await liveConversationCoordinator
                        .prepareForPrerecordingPreFiller(firstEligibleItem)
                }
                print(
                    "[TuringLiveConversation] pre-PR preparation launched " +
                        "itemID=\(firstEligibleItem.id) " +
                        "authoredPlaybackBlocked=false"
                )
                // Give the already-enqueued MainActor job a scheduling turn
                // before orientation audio begins. This does not wait for
                // package loading, reveal completion, or microphone setup.
                await Task.yield()
            } else {
                preFillerPreparationTask = nil
            }
            defer { preFillerPreparationTask?.cancel() }
            await route.runFixedLeadInIfNeeded(
                descriptor: descriptor,
                identity: identity
            )
            try await route.playOpenIfNeeded(
                descriptor: descriptor,
                identity: identity
            )
            if let primary = mediaPlan.items.first(
                where: { $0.orientationMode == .runnerOwnedPrimary }
            ) {
                _ = try await TuringPrerecordingOrientationCoordinator.shared.run(
                    TuringPrerecordingOrientationRequest(
                        flowIdentity: identity,
                        descriptor: descriptor,
                        mediaItemID: primary.id,
                        mediaRole: primary.role,
                        interactionSurface:
                            descriptor.transmission.effectiveInteractionSurface
                    )
                )
            }
            try await route.beginPrerecordingLeadInIfNeeded(
                descriptor: descriptor,
                identity: identity
            )
            try await route.waitForPrerecordingLeadInCompletionIfNeeded(
                descriptor: descriptor,
                identity: identity
            )
            for item in mediaPlan.items {
                try await playback.enqueueAuthoredMedia(item)
            }
            await playback.sealAuthoredInput()
            try await playback.waitUntilAuthoredPlaybackFinished()
            await liveConversationCoordinator.authoredFlowDidComplete(
                reason: "authoredFlowCompleted.\(descriptor.scriptPointID)"
            )
        } catch {
            await liveConversationCoordinator.detach(
                reason: "authoredFlowFailed.\(descriptor.scriptPointID)"
            )
            await playback.runCancelled(
                reason: "authoredFlowFailed.\(error.localizedDescription)"
            )
            throw error
        }

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

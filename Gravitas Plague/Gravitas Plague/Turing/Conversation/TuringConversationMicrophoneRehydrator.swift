import Foundation

nonisolated struct TuringConversationMicrophoneRehydration: Sendable, Equatable {
    let episodeID: TuringEpisodeID
    let segmentID: String
    let maximumNarrativeOrdinal: Int
    let slots: [StoryInteractionSurfaceID: TuringLatchedMicrophoneSlot]
}

struct TuringConversationMicrophoneRehydrator: Sendable {
    private let catalogStore: TuringLiveConversationCatalogStore
    private let descriptorStore = TuringFlowDescriptorStore()
    private let prerecordingStore = TuringPrerecordingStore()

    init(bundle: Bundle = .main) throws {
        catalogStore = try TuringLiveConversationCatalogStore(bundle: bundle)
    }

    func resolveSlots(
        target: TuringStoryContinuationTarget,
        generation: UInt64,
        bundle: Bundle = .main
    ) throws -> TuringConversationMicrophoneRehydration {
        let episodeID = target.episodeID
        let checkpointRawValue: String
        let contentRevision: String
        var completedChapter01Branches = Set<Chapter01PostRobotBranch>()
        switch target {
        case .prologue(let snapshot):
            checkpointRawValue = String(snapshot.checkpoint.rawValue)
            contentRevision = snapshot.contentRevision
        case .chapter01(let snapshot):
            let checkpoint = snapshot.checkpoint.supportedContinuationCheckpoint
                ?? snapshot.checkpoint
            checkpointRawValue = checkpoint.rawValue
            contentRevision = snapshot.contentRevision
            completedChapter01Branches = snapshot.postRobot
                .normalizedForSequentialUnlock().completedBranches
        case .chapter02(let snapshot):
            checkpointRawValue = snapshot.checkpoint.rawValue
            contentRevision = snapshot.contentRevision
        case .chapter03(let snapshot):
            checkpointRawValue = snapshot.checkpoint.rawValue
            contentRevision = snapshot.contentRevision
        }

        guard let checkpoint = catalogStore.checkpoint(
            episodeID: episodeID,
            rawValue: checkpointRawValue
        ),
        let episode = catalogStore.episode(episodeID) else {
            throw TuringRuntimeError.invalidConfig(
                "No microphone routing checkpoint exists for \(episodeID.rawValue).\(checkpointRawValue)."
            )
        }
        guard episode.contentRevision == contentRevision else {
            throw TuringRuntimeError.invalidConfig(
                "Microphone routing content revision does not match \(episodeID.rawValue)."
            )
        }

        var maximumOrdinal = checkpoint.maximumNarrativeOrdinal
        if episodeID == .chapter01,
           checkpointRawValue == Chapter01Checkpoint.postRobotHub.rawValue {
            if completedChapter01Branches.contains(.dadFrame) {
                maximumOrdinal = 1000
            }
            if completedChapter01Branches.contains(.walkie) {
                maximumOrdinal = 1200
            }
            if completedChapter01Branches.contains(.hamReceiver) {
                maximumOrdinal = 1400
            }
        }

        let moments = episode.moments.filter {
            $0.segmentID == checkpoint.segmentID &&
                $0.narrativeOrdinal <= maximumOrdinal
        }.sorted {
            $0.narrativeOrdinal < $1.narrativeOrdinal
        }
        let latestBySurface = moments.reduce(into: [
            StoryInteractionSurfaceID:
                TuringLiveConversationCatalog.Moment
        ]()) { result, moment in
            result[moment.interactionSurface] = moment
        }

        let syntheticSequenceID = UUID()
        var slots: [StoryInteractionSurfaceID: TuringLatchedMicrophoneSlot] = [:]
        for (surface, moment) in latestBySurface {
            let descriptor = try descriptorStore.require(moment.scriptPointID)
            let recording = try prerecordingStore.descriptor(
                id: moment.authoredPrerecordingID
            )
            let role: TuringAuthoredMediaItem.Role =
                descriptor.transmission.prerecordingID ==
                    moment.authoredPrerecordingID
                ? .primaryPrerecording
                : .authoredBridge
            let item = TuringAuthoredMediaItem(
                scriptPointID: moment.scriptPointID,
                id: moment.authoredPrerecordingID,
                role: role,
                fileURL: try prerecordingStore.audioURL(for: recording),
                liveConversationCatalogEntry: moment,
                orientationMode: .none
            )
            let identity = TuringFlowIdentity(
                scriptPointID: moment.scriptPointID,
                characterID: descriptor.transmission.characterID,
                prerecordingID: moment.authoredPrerecordingID,
                voicePromptID: descriptor.transmission.voicePromptID
                    ?? "routing.rehydration",
                interactionSurface: surface,
                playbackRunID: "continue.routing.\(moment.momentID)"
            )
            let seed = try TuringLiveConversationSeedResolver().resolve(
                entry: moment,
                item: item,
                descriptor: descriptor,
                parentSequenceID: syntheticSequenceID,
                identity: identity,
                microphoneGeneration: generation,
                bundle: bundle
            )
            slots[surface] = TuringLatchedMicrophoneSlot(
                slotID: UUID(),
                generation: generation,
                episodeID: episodeID,
                segmentID: checkpoint.segmentID,
                surface: surface,
                activationMomentID: moment.momentID,
                targetCharacterID: seed.targetContext.targetCharacterID,
                seed: seed
            )
        }

        print(
            "[TuringLiveConversation] Continue routing resolved " +
                "episodeID=\(episodeID.rawValue) " +
                "checkpoint=\(checkpointRawValue) " +
                "segmentID=\(checkpoint.segmentID) " +
                "maximumOrdinal=\(maximumOrdinal) " +
                "surfaces=\(slots.keys.map(\.rawValue).sorted()) " +
                "modelWork=false"
        )
        return TuringConversationMicrophoneRehydration(
            episodeID: episodeID,
            segmentID: checkpoint.segmentID,
            maximumNarrativeOrdinal: maximumOrdinal,
            slots: slots
        )
    }
}

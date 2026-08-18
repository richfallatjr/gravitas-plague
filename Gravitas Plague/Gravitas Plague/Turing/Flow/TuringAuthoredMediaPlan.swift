import Foundation

nonisolated struct TuringAuthoredMediaItem: Sendable, Equatable {
    enum Role: String, Sendable, Equatable {
        case openingCue
        case primaryPrerecording
        case authoredBridge
        case closingBumper
    }

    enum OrientationMode: String, Sendable, Equatable {
        case none
        case runnerOwnedPrimary
        case playbackOwnedBridge
    }

    let scriptPointID: String
    let id: String
    let role: Role
    let fileURL: URL
    let liveConversationCatalogEntry:
        TuringLiveConversationCatalog.Entry?
    let orientationMode: OrientationMode

    init(
        scriptPointID: String = "unknown",
        id: String,
        role: Role,
        fileURL: URL,
        liveConversationCatalogEntry:
            TuringLiveConversationCatalog.Entry? = nil,
        orientationMode: OrientationMode = .none
    ) {
        self.scriptPointID = scriptPointID
        self.id = id
        self.role = role
        self.fileURL = fileURL
        self.liveConversationCatalogEntry = liveConversationCatalogEntry
        self.orientationMode = orientationMode
    }
}

nonisolated struct TuringAuthoredMediaPlan: Sendable, Equatable {
    let scriptPointID: String
    let items: [TuringAuthoredMediaItem]
}

struct TuringAuthoredMediaPlanResolver: Sendable {
    private let prerecordingStore: any TuringPrerecordingLoading
    private let liveConversationCatalog:
        TuringLiveConversationCatalogStore?

    init(
        prerecordingStore: any TuringPrerecordingLoading =
            TuringPrerecordingStore(),
        liveConversationCatalog:
            TuringLiveConversationCatalogStore? = nil
    ) throws {
        self.prerecordingStore = prerecordingStore
        if let liveConversationCatalog {
            self.liveConversationCatalog = liveConversationCatalog
        } else {
            self.liveConversationCatalog =
                try TuringLiveConversationCatalogStore()
        }
    }

    func resolve(
        descriptor: TuringFlowDescriptor,
        treatment: StoryPlayModeTreatment
    ) throws -> TuringAuthoredMediaPlan {
        let ids: [(String, TuringAuthoredMediaItem.Role)]
        switch treatment.authoredMediaPolicy {
        case .standard:
            var ordered: [(String, TuringAuthoredMediaItem.Role)] = [
                (descriptor.transmission.prerecordingID, .primaryPrerecording)
            ]
            if let stages = descriptor.transmission.generationPipeline?.stages {
                ordered.append(contentsOf: stages.compactMap { stage in
                    stage.authoredPrerecordingAfterStageID.map {
                        ($0, .authoredBridge)
                    }
                })
            }
            ids = ordered
        case .replaceWithPrerecordings(let replacements):
            ids = replacements.map { ($0, .authoredBridge) }
        }

        var seen = Set<String>()
        let items = try ids.compactMap { id, role -> TuringAuthoredMediaItem? in
            guard id != "none", seen.insert(id).inserted else { return nil }
            let recording = try prerecordingStore.descriptor(id: id)
            let orientationMode: TuringAuthoredMediaItem.OrientationMode
            switch role {
            case .primaryPrerecording
                where TuringPrerecordingOrientationEligibility.permits(
                    descriptor: descriptor,
                    role: role
                ):
                orientationMode = .runnerOwnedPrimary
            case .authoredBridge
                where TuringPrerecordingOrientationEligibility.permits(
                    descriptor: descriptor,
                    role: role
                ):
                orientationMode = .playbackOwnedBridge
            case .primaryPrerecording, .authoredBridge,
                 .openingCue, .closingBumper:
                orientationMode = .none
            }
            return TuringAuthoredMediaItem(
                scriptPointID: descriptor.scriptPointID,
                id: id,
                role: role,
                fileURL: try prerecordingStore.audioURL(for: recording),
                liveConversationCatalogEntry:
                    (role == .primaryPrerecording || role == .authoredBridge)
                    ? liveConversationCatalog?.entry(
                        scriptPointID: descriptor.scriptPointID,
                        authoredPrerecordingID: id
                    )
                    : nil,
                orientationMode: orientationMode
            )
        }
        guard items.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Play mode found no authored media for \(descriptor.scriptPointID)."
            )
        }
        return TuringAuthoredMediaPlan(
            scriptPointID: descriptor.scriptPointID,
            items: items
        )
    }
}

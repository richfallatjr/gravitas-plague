import Foundation

nonisolated struct TuringLiveConversationCatalog: Codable, Sendable, Equatable {
    struct Episode: Codable, Sendable, Equatable {
        let episodeID: TuringEpisodeID
        let contentRevision: String
        let segments: [Segment]
        let moments: [Moment]
        let checkpoints: [Checkpoint]
    }

    struct Segment: Codable, Sendable, Equatable {
        enum BoundaryKind: String, Codable, Sendable, Equatable {
            case chapterStart
            case battle
            case antigenDroneSequence
        }

        let segmentID: String
        let startsAtBoundaryID: String
        let boundaryKind: BoundaryKind
        let narrativeOrdinal: Int
    }

    struct Moment: Codable, Sendable, Equatable {
        struct VoicePromptSource: Codable, Sendable, Equatable {
            enum Kind: String, Codable, Sendable, Equatable {
                case transmission
                case generationPipelineStage
                case explicit
            }

            let kind: Kind
            let stageID: String?
            let voicePromptID: String?
        }

        enum Retention: String, Codable, Sendable, Equatable {
            case currentAuthoredItem
            case currentFlowSequence
            case untilExplicitInvalidation
        }

        let momentID: String
        let segmentID: String
        let narrativeOrdinal: Int
        let scriptPointID: String
        let authoredPrerecordingID: String
        let voicePromptSource: VoicePromptSource
        let interactionSurface: StoryInteractionSurfaceID
        let speakerCharacterID: TuringConversationCharacterID
        let conversationTargetCharacterID: TuringConversationCharacterID
        let retention: Retention
    }

    typealias Entry = Moment

    struct Checkpoint: Codable, Sendable, Equatable {
        let checkpointRawValue: String
        let segmentID: String
        let maximumNarrativeOrdinal: Int
    }

    let schemaVersion: Int
    let episodes: [Episode]
}

struct TuringLiveConversationCatalogStore: Sendable {
    private let catalog: TuringLiveConversationCatalog

    init(bundle: Bundle = .main) throws {
        catalog = try TuringResourceLoader.decodeResource(
            TuringLiveConversationCatalog.self,
            resourcePath: "Turing/LiveConversation/catalog.json",
            bundle: bundle
        )
        guard catalog.schemaVersion == 2 else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation catalog schemaVersion must be 2."
            )
        }
        let keys = entries.map {
            "\($0.scriptPointID)|\($0.authoredPrerecordingID)"
        }
        guard Set(keys).count == keys.count else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation catalog contains duplicate entries."
            )
        }
    }

    func entry(
        scriptPointID: String,
        authoredPrerecordingID: String
    ) -> TuringLiveConversationCatalog.Entry? {
        entries.first {
            $0.scriptPointID == scriptPointID &&
                $0.authoredPrerecordingID == authoredPrerecordingID
        }
    }

    var entries: [TuringLiveConversationCatalog.Entry] {
        catalog.episodes.flatMap(\.moments)
    }

    var routingCatalog: TuringLiveConversationCatalog {
        catalog
    }

    func episode(
        _ episodeID: TuringEpisodeID
    ) -> TuringLiveConversationCatalog.Episode? {
        catalog.episodes.first { $0.episodeID == episodeID }
    }

    func episode(
        containing entry: TuringLiveConversationCatalog.Entry
    ) -> TuringLiveConversationCatalog.Episode? {
        catalog.episodes.first { episode in
            episode.moments.contains { $0.momentID == entry.momentID }
        }
    }

    func firstSegment(
        for episodeID: TuringEpisodeID
    ) -> TuringLiveConversationCatalog.Segment? {
        episode(episodeID)?.segments.min {
            $0.narrativeOrdinal < $1.narrativeOrdinal
        }
    }

    func checkpoint(
        episodeID: TuringEpisodeID,
        rawValue: String
    ) -> TuringLiveConversationCatalog.Checkpoint? {
        episode(episodeID)?.checkpoints.first {
            $0.checkpointRawValue == rawValue
        }
    }
}

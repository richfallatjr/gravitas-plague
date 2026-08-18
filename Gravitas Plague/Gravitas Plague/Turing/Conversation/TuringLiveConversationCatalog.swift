import Foundation

nonisolated struct TuringLiveConversationCatalog: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
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

        let scriptPointID: String
        let authoredPrerecordingID: String
        let voicePromptSource: VoicePromptSource
        let interactionSurface: StoryInteractionSurfaceID
        let retention: Retention
    }

    let schemaVersion: Int
    let entries: [Entry]
}

struct TuringLiveConversationCatalogStore: Sendable {
    private let catalog: TuringLiveConversationCatalog

    init(bundle: Bundle = .main) throws {
        catalog = try TuringResourceLoader.decodeResource(
            TuringLiveConversationCatalog.self,
            resourcePath: "Turing/LiveConversation/catalog.json",
            bundle: bundle
        )
        guard catalog.schemaVersion == 1 else {
            throw TuringRuntimeError.invalidConfig(
                "Live conversation catalog schemaVersion must be 1."
            )
        }
        let keys = catalog.entries.map {
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
        catalog.entries.first {
            $0.scriptPointID == scriptPointID &&
                $0.authoredPrerecordingID == authoredPrerecordingID
        }
    }

    var entries: [TuringLiveConversationCatalog.Entry] {
        catalog.entries
    }
}

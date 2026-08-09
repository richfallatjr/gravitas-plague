import Foundation

struct TuringFlowGenerationPipelineDescriptor: Codable, Sendable, Hashable {
    enum RadioBridgeMode: String, Codable, Sendable, Hashable {
        case none
        case bigMikeStaticAndFiller
    }

    struct Stage: Codable, Sendable, Hashable {
        enum Kind: String, Codable, Sendable, Hashable {
            case voicePrompt
            case voiceScriptLongform
        }

        struct ContextSource: Codable, Sendable, Hashable {
            enum Kind: String, Codable, Sendable, Hashable {
                case prerecordingTranscript
                case stageSourceTranscript
            }

            let kind: Kind
            let stageID: String?
        }

        let stageID: String
        let kind: Kind
        let sourceResourcePath: String?
        let voicePromptID: String?
        let defaultEmotion: String
        let contextSource: ContextSource
        let authoredPrerecordingAfterStageID: String?

        init(
            stageID: String,
            kind: Kind,
            sourceResourcePath: String?,
            voicePromptID: String?,
            defaultEmotion: String,
            contextSource: ContextSource,
            authoredPrerecordingAfterStageID: String? = nil
        ) {
            self.stageID = stageID
            self.kind = kind
            self.sourceResourcePath = sourceResourcePath
            self.voicePromptID = voicePromptID
            self.defaultEmotion = defaultEmotion
            self.contextSource = contextSource
            self.authoredPrerecordingAfterStageID =
                authoredPrerecordingAfterStageID
        }
    }

    let schemaVersion: Int
    let radioBridgeMode: RadioBridgeMode
    let stages: [Stage]
}

extension TuringFlowDescriptor.Transmission {
    var usesLegacyVoicePrompt: Bool {
        voicePromptID != nil && generationPipeline == nil
    }

    var usesCompositePipeline: Bool {
        voicePromptID == nil && generationPipeline != nil
    }

    var isPrerecordingOnly: Bool {
        voicePromptID == nil && generationPipeline == nil
    }
}

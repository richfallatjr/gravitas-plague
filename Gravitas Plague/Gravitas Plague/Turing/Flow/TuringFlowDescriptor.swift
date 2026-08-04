import Foundation

struct TuringFlowDescriptor: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let scriptPointID: String
    let trigger: Trigger
    let transmission: Transmission
    let progression: Progression

    struct Trigger: Codable, Sendable, Hashable {
        let kind: Kind
        let delaySeconds: Double

        enum Kind: String, Codable, Sendable, Hashable {
            case userPlay
            case priorConversationPlaybackCompleted
            case priorScriptPointCompleted
            case manualDebug
        }
    }

    struct Transmission: Codable, Sendable, Hashable {
        let prerecordingID: String
        let voicePromptID: String?
        let characterID: String
        let conversationKey: String
        let outputRoute: TuringVoiceOutputContext
        let computeStart: ComputeStart
        let fillerMode: FillerMode
        let commSFX: CommSFX
        let fixedLeadInSeconds: Double?
        let generationPipeline: TuringFlowGenerationPipelineDescriptor?
        let interactionSurface: StoryInteractionSurfaceID?
        let backgroundMusic: TuringFlowBackgroundMusicDescriptor?

        init(
            prerecordingID: String,
            voicePromptID: String?,
            characterID: String,
            conversationKey: String,
            outputRoute: TuringVoiceOutputContext,
            computeStart: ComputeStart,
            fillerMode: FillerMode,
            commSFX: CommSFX,
            fixedLeadInSeconds: Double?,
            generationPipeline: TuringFlowGenerationPipelineDescriptor?,
            interactionSurface: StoryInteractionSurfaceID? = nil,
            backgroundMusic: TuringFlowBackgroundMusicDescriptor? = nil
        ) {
            self.prerecordingID = prerecordingID
            self.voicePromptID = voicePromptID
            self.characterID = characterID
            self.conversationKey = conversationKey
            self.outputRoute = outputRoute
            self.computeStart = computeStart
            self.fillerMode = fillerMode
            self.commSFX = commSFX
            self.fixedLeadInSeconds = fixedLeadInSeconds
            self.generationPipeline = generationPipeline
            self.interactionSurface = interactionSurface
            self.backgroundMusic = backgroundMusic
        }

        var effectiveInteractionSurface: StoryInteractionSurfaceID {
            interactionSurface ?? .walkie
        }

        enum ComputeStart: String, Codable, Sendable, Hashable {
            /// Start Foundation immediately before the prerecording is queued.
            case withPrerecording

            /// Start Foundation before fixed lead-in and prerecording playback.
            case beforePrerecording

            /// Start background media, await the complete Foundation response,
            /// then start prerecording playback and TTS rendering together.
            case foundationBeforePrerecording

            /// The episode controller starts this point only after the prior
            /// point has completed. Foundation begins immediately on entry.
            case afterPriorPoint
        }

        enum FillerMode: String, Codable, Sendable, Hashable {
            /// Used for generated-only conversation runs.
            case onePrerollThenComputeGap

            /// The prerecording is the first buffer. If segment zero is late
            /// after the PR, play character-specific filler/dead air.
            case continuousFromPrerecordingToGenerated

            case none
        }

        struct CommSFX: Codable, Sendable, Hashable {
            let openBeforePrerecording: Bool
            let sendAfterGenerated: Bool
            let sendingLeadInAfterGeneratedSeconds: Double?
        }
    }

    struct Progression: Codable, Sendable, Hashable {
        let nextScriptPointID: String?
        let automaticAdvance: Bool
        let interactionGateAfterCompletion: InteractionGate

        enum InteractionGate: String, Codable, Sendable, Hashable {
            case closed
            case microphone
            case play
        }
    }
}

struct TuringFlowBackgroundMusicDescriptor:
    Codable,
    Sendable,
    Hashable
{
    enum StopBoundary: String, Codable, Sendable, Hashable {
        case promptVoicePlaybackCompleted
    }

    let resourcePath: String
    let gainDB: Float
    let loops: Bool
    let fadeInSeconds: Double
    let fadeOutSeconds: Double
    let stopBoundary: StopBoundary
}

extension TuringFlowDescriptor.Progression {
    var effectiveInteractionGateAfterCompletion:
        InteractionGate {
        automaticAdvance && nextScriptPointID != nil
            ? .closed
            : interactionGateAfterCompletion
    }
}

nonisolated enum TuringFlowTriggerSource: Sendable, Hashable {
    case userPlay
    case priorConversationPlaybackCompleted(parentScriptPointID: String)
    case priorScriptPointCompleted(parentScriptPointID: String)
    case continuationRestore(checkpoint: TuringPrologueCheckpoint)
    case manualDebug
}

extension TuringFlowTriggerSource {
    var interactionStartMode: TuringInteractionStartMode {
        switch self {
        case .priorConversationPlaybackCompleted,
             .priorScriptPointCompleted:
            return .automatic
        case .userPlay,
             .continuationRestore,
             .manualDebug:
            return .manual
        }
    }

    var kind: TuringFlowDescriptor.Trigger.Kind {
        switch self {
        case .userPlay:
            return .userPlay
        case .priorConversationPlaybackCompleted:
            return .priorConversationPlaybackCompleted
        case .priorScriptPointCompleted:
            return .priorScriptPointCompleted
        case .continuationRestore(let checkpoint):
            switch checkpoint {
            case .notStarted:
                return .userPlay
            case .script01ConversationVoiceCompleted:
                return .priorConversationPlaybackCompleted
            case .script04ConversationVoiceCompleted:
                return .priorConversationPlaybackCompleted
            case .script02PromptVoiceCompleted:
                return .priorScriptPointCompleted
            case .script01PromptVoiceCompleted,
                 .script03PromptVoiceCompleted,
                 .script04PromptVoiceCompleted,
                 .script05PromptVoiceCompleted:
                return .userPlay
            }
        case .manualDebug:
            return .manualDebug
        }
    }

    var logValue: String {
        switch self {
        case .userPlay:
            return "userPlay"
        case .priorConversationPlaybackCompleted(let parent):
            return "priorConversationPlaybackCompleted.\(parent)"
        case .priorScriptPointCompleted(let parent):
            return "priorScriptPointCompleted.\(parent)"
        case .continuationRestore(let checkpoint):
            return "continuationRestore.\(checkpoint)"
        case .manualDebug:
            return "manualDebug"
        }
    }

}

protocol TuringFlowDescriptorLoading: Sendable {
    func require(_ scriptPointID: String) throws -> TuringFlowDescriptor
}

struct TuringFlowDescriptorStore: TuringFlowDescriptorLoading, Sendable {
    func require(_ scriptPointID: String) throws -> TuringFlowDescriptor {
        let value = try TuringResourceLoader.decodeResource(
            TuringFlowDescriptor.self,
            resourcePath: "Turing/ScriptPoints/\(scriptPointID).json"
        )

        guard value.schemaVersion == 2 else {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow \(scriptPointID) schemaVersion must be 2."
            )
        }
        guard value.scriptPointID == scriptPointID else {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow ID mismatch. Expected \(scriptPointID), got \(value.scriptPointID)."
            )
        }

        let required = [
            value.scriptPointID,
            value.transmission.prerecordingID,
            value.transmission.characterID,
            value.transmission.conversationKey,
            value.transmission.outputRoute.rawValue
        ]

        guard required.allSatisfy({
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }) else {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow \(scriptPointID) contains an empty required identifier."
            )
        }

        guard value.transmission.usesLegacyVoicePrompt !=
                value.transmission.usesCompositePipeline else {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow \(scriptPointID) must define exactly one generation form."
            )
        }

        if value.transmission.usesLegacyVoicePrompt {
            guard let promptID = value.transmission.voicePromptID,
                  promptID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw TuringRuntimeError.invalidConfig(
                    "Turing Flow \(scriptPointID) legacy voicePromptID must not be empty."
                )
            }
        }

        guard value.trigger.delaySeconds >= 0 else {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow \(scriptPointID) trigger delay must be nonnegative."
            )
        }

        if let leadIn = value.transmission.fixedLeadInSeconds,
           leadIn < 0 {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow \(scriptPointID) fixed lead-in must be nonnegative."
            )
        }

        if let leadIn = value.transmission.commSFX
            .sendingLeadInAfterGeneratedSeconds,
           leadIn < 0 {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow \(scriptPointID) post-send lead-in must be nonnegative."
            )
        }

        if value.progression.automaticAdvance,
           value.progression.nextScriptPointID == nil {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow \(scriptPointID) cannot auto-advance without a nextScriptPointID."
            )
        }

        return value
    }
}

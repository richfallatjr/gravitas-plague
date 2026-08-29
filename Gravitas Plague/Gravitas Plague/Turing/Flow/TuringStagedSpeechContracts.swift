import Foundation

struct TuringPreparedSpeechBatch: Sendable, Equatable {
    let stageID: String
    let batchID: String
    let isFinalBatchForStage: Bool
    let segments: [TuringSpeechSegment]
}

struct TuringCommittedSpeechStage: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case scriptVoice
        case promptVoice
    }

    let stageID: String
    let kind: Kind
    let globalRange: Range<Int>
    let segments: [TuringSpeechSegment]
}

struct TuringSpeechStageFailure: Sendable, Equatable {
    let stageID: String
    let stageKind: TuringCommittedSpeechStage.Kind
    let reason: String
}

struct TuringStagedSpeechRunReport: Sendable, Equatable {
    let committedStages: [TuringCommittedSpeechStage]
    let failedStages: [TuringSpeechStageFailure]
    let finalExpectedSegmentCount: Int
    let completedPlaybackCount: Int
    let skippedSegmentIndices: Set<Int>

    var completedWithoutStageFailure: Bool {
        failedStages.isEmpty &&
            skippedSegmentIndices.isEmpty &&
            completedPlaybackCount == finalExpectedSegmentCount
    }
}

struct TuringSpeechStageContext: Sendable {
    let descriptor: TuringFlowDescriptor
    let character: TuringCharacterRuntimeDefinition
    let prerecording: TuringPrerecordingDescriptor
    let stageSourceTranscripts: [String: String]
}

struct TuringSpeechStageExecutionResult: Sendable {
    let normalizedSourceTranscript: String?
    let promptVoiceContext: TuringAuthoredPromptVoiceContext?
    let failedBatchDescriptions: [String]
}

struct TuringAuthoredSpeechBridge: Sendable, Equatable {
    let mediaItem: TuringAuthoredMediaItem
    let conversationTranscript: String?

    var prerecordingID: String { mediaItem.id }
    var fileURL: URL { mediaItem.fileURL }
}

protocol TuringSpeechStageExecuting: Sendable {
    var kind: TuringFlowGenerationPipelineDescriptor.Stage.Kind { get }

    func execute(
        stage: TuringFlowGenerationPipelineDescriptor.Stage,
        context: TuringSpeechStageContext,
        onPreparedBatch: @Sendable (TuringPreparedSpeechBatch) async throws -> Void
    ) async throws -> TuringSpeechStageExecutionResult
}

protocol TuringVoiceScriptLongformPlanning: Sendable {
    func makeSourcePlan(
        request: TuringLongformVoiceScriptRequest
    ) throws -> TuringAudiobookSourcePlan

    func prepareSection(
        _ section: TuringAudiobookSourceSection,
        in plan: TuringAudiobookSourcePlan,
        request: TuringLongformVoiceScriptRequest
    ) async throws -> TuringAudiobookSectionSegmentationResult
}

extension TuringVoiceScriptLongformRunner: TuringVoiceScriptLongformPlanning {
}

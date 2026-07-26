import Foundation

/// Legacy single-stage result retained for the existing promptVoice path.
/// Descriptor-driven multi-stage points use TuringStagedSpeechRunCoordinator.
struct TuringFlowCompositeSpeechPlan: Sendable {
    let segments: [TuringSpeechSegment]
    let promptVoiceContext: TuringAuthoredPromptVoiceContext
}

import Foundation

protocol TuringPrerecordingLoading: Sendable {
    func descriptor(id: String) throws -> TuringPrerecordingDescriptor
    func audioURL(
        for descriptor: TuringPrerecordingDescriptor
    ) throws -> URL
}

extension TuringPrerecordingStore: TuringPrerecordingLoading {
}

protocol TuringVoicePromptTriggerLoading: Sendable {
    func descriptor(id: String) throws -> TuringVoicePromptTriggerDescriptor
}

extension TuringVoicePromptTriggerStore: TuringVoicePromptTriggerLoading {
}

protocol TuringFlowVoicePromptGenerating: Sendable {
    func generateVoicePrompt(
        _ request: VoicePromptRequest
    ) async throws -> TuringVoicePromptPlan
}

extension TuringDialogueService: TuringFlowVoicePromptGenerating {
}

import Foundation

protocol QwenTTSModelHost: Sendable {
    var modelID: String { get }
    var modelRevision: String { get }
    var quantization: String { get }
    var tokenizerRevision: String { get }

    func loadIfNeeded() async throws
    func assertGPUAvailable() async throws
    func generatePhase0BareBaseSmoke(
        _ request: QwenPhase0SmokeRequest
    ) async throws -> QwenWaveform
    func makeSession() async throws -> QwenTTSSynthesisSession
}

protocol QwenTTSSynthesisSession: Sendable {
    func synthesize(
        text: String,
        emotion: String,
        voice: TuringVoiceDescriptor,
        settings: QwenGenerationSettings
    ) async throws -> QwenWaveform

    func releaseTransientState() async
}

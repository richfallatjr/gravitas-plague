import Foundation

actor QwenMLXAudioModelHost: QwenTTSModelHost {
    let modelID: String
    let modelRevision: String
    let quantization: String
    let tokenizerRevision: String

    init(
        descriptor: TuringModelDescriptor,
        runtime: TuringRuntimeConfig,
        bundle: Bundle = .main
    ) {
        _ = runtime
        _ = bundle
        modelID = descriptor.id
        modelRevision = descriptor.modelRevision
        quantization = descriptor.quantization
        tokenizerRevision = descriptor.tokenizerRevision
    }

    func assertGPUAvailable() async throws {
        throw disabledError()
    }

    func generatePhase0BareBaseSmoke(
        _ request: QwenPhase0SmokeRequest
    ) async throws -> QwenWaveform {
        _ = request
        throw disabledError()
    }

    func loadIfNeeded() async throws {
        throw disabledError()
    }

    func makeSession() async throws -> QwenTTSSynthesisSession {
        throw disabledError()
    }

    private func disabledError() -> TuringRuntimeError {
        TuringRuntimeError.qwenModelLoadFailed(
            "Legacy Qwen host disabled. Use the native Story episode picker canary."
        )
    }
}

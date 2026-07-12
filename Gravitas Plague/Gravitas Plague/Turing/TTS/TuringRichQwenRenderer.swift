import Foundation

actor TuringRichQwenRenderer {
    func render(
        segments: [TuringSpeechSegment],
        runID: String,
        onStarted: @Sendable @escaping (Int) async -> Void,
        onFinished:
            @Sendable @escaping (
                Int,
                TuringComputeGapGeneratedAudio
            ) async -> Void,
        onSkipped:
            @Sendable @escaping (
                Int,
                String
            ) async -> Void
    ) async throws {
        let runtime =
            try TuringCharacterRuntimeStore()
                .require("rich")
        _ = try await TuringCharacterQwenRenderer(
            runtime: runtime
        ).render(
            segments: segments,
            runID: runID,
            onStarted: onStarted,
            onFinished: onFinished,
            onSkipped: onSkipped
        )
    }
}

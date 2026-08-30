import Foundation

final class TuringQwenNativeSpeechDecoderSession {
    let modelRoot: URL
    let config: TuringQwenNativeSpeechTokenizerConfig
    let reader: TuringQwenNativeSafetensorsReader

    init(modelRoot: URL) throws {
        self.modelRoot = modelRoot
        self.config = try TuringQwenNativeSpeechTokenizerConfig.load(
            from: modelRoot
        )
        let index = try TuringQwenNativeSafetensorsIndex.load(
            from: modelRoot
                .appendingPathComponent("speech_tokenizer", isDirectory: true)
                .appendingPathComponent("model.safetensors")
        )
        self.reader = TuringQwenNativeSafetensorsReader(index: index)
    }

    func decode(
        rows: [[Int]],
        performanceMode: TuringQwenNativePerformanceMode,
        diagnosticContext: TuringQwenNativeSpeechDecoderDiagnosticContext? = nil
    ) throws -> TuringQwenNativeAudio {
        try TuringQwenNativeMLXErrorBoundary.run(
            context: TuringQwenNativeMLXExecutionContext(
                runID: diagnosticContext?.runID ?? "standaloneSpeechDecode",
                instanceID: diagnosticContext.flatMap {
                    TuringQwenNativeFreshInstanceID(rawValue: $0.instanceID)
                },
                segmentIndex: diagnosticContext?.segmentIndex,
                decodeID: diagnosticContext?.decodeID,
                phase: .speechDecoder,
                stage: "speechDecoder.session"
            )
        ) {
            try TuringQwenNativeSpeechDecoder.decodeRows(
                rows,
                config: config,
                reader: reader,
                performanceMode: performanceMode,
                diagnosticContext: diagnosticContext
            )
        }
    }
}

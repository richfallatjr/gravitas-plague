import Foundation

public actor TuringQwenNativeSpeechDecodeGate {
    public static let shared = TuringQwenNativeSpeechDecodeGate()

    private var nextDecodeID = 0

    private init() {}

    func decode(
        codebookRows: [[Int]],
        modelRoot: URL,
        performanceMode: TuringQwenNativePerformanceMode,
        queuedAt: Date
    ) throws -> TuringQwenNativeAudio {
        let decodeID = nextDecodeID
        nextDecodeID += 1
        let acquiredAt = Date()
        let before = TuringQwenNativeProcessMemoryProbe.snapshot()

        print(
            """
            [TuringQwenSpeechDecodeGate] acquired
              decodeID: \(decodeID)
              waitSeconds: \(String(format: "%.3f", acquiredAt.timeIntervalSince(queuedAt)))
              totalRows: \(codebookRows.count)
              physFootprintBeforeMB: \(String(format: "%.1f", before.physFootprintMB))
              concurrentDecoderLimit: 1
              qwenGenerationConcurrencyUnchanged: true
            """
        )

        defer {
            let after = TuringQwenNativeProcessMemoryProbe.snapshot()
            print(
                """
                [TuringQwenSpeechDecodeGate] released
                  decodeID: \(decodeID)
                  heldSeconds: \(String(format: "%.3f", Date().timeIntervalSince(acquiredAt)))
                  physFootprintAfterMB: \(String(format: "%.1f", after.physFootprintMB))
                """
            )
        }

        return try TuringQwenNativeSpeechDecoder.decode(
            codebookRows: codebookRows,
            modelRoot: modelRoot,
            performanceMode: performanceMode
        )
    }
}

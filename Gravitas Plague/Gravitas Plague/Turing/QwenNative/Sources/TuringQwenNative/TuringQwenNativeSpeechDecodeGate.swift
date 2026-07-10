import Foundation

public actor TuringQwenNativeSpeechDecodeGate {
    public static let shared = TuringQwenNativeSpeechDecodeGate()
    private static let maximumConcurrentGenerations = 2

    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var nextDecodeID = 0
    private var nextGenerationID = 0
    private var activeGenerationCount = 0
    private var decodeActive = false
    private var decodeWaiters: [Waiter] = []
    private var generationWaiters: [Waiter] = []

    private init() {}

    func beginGeneration() async {
        let generationID = nextGenerationID
        nextGenerationID += 1
        let queuedAt = Date()

        if decodeActive ||
            decodeWaiters.isEmpty == false ||
            activeGenerationCount >= Self.maximumConcurrentGenerations {
            await withCheckedContinuation { continuation in
                generationWaiters.append(
                    Waiter(id: generationID, continuation: continuation)
                )
            }
        } else {
            activeGenerationCount += 1
        }

        print(
            """
            [TuringQwenGPUGate] generation acquired
              generationID: \(generationID)
              waitSeconds: \(String(format: "%.3f", Date().timeIntervalSince(queuedAt)))
              activeGenerationCount: \(activeGenerationCount)
              generationConcurrencyLimit: \(Self.maximumConcurrentGenerations)
              decoderActive: \(decodeActive)
            """
        )
    }

    func cancelGeneration(reason: String) {
        guard activeGenerationCount > 0 else { return }
        activeGenerationCount -= 1
        print(
            """
            [TuringQwenGPUGate] generation cancelled
              reason: \(reason)
              activeGenerationCount: \(activeGenerationCount)
            """
        )
        admitNextDecodeIfPossible()
        admitWaitingGenerationsIfPossible()
    }

    func decodeAfterGeneration(
        codebookRows: [[Int]],
        modelRoot: URL,
        performanceMode: TuringQwenNativePerformanceMode,
        queuedAt: Date
    ) async throws -> TuringQwenNativeAudio {
        let decodeID = nextDecodeID
        nextDecodeID += 1

        guard activeGenerationCount > 0 else {
            throw TuringQwenNativeError.invalidConfig(
                "Speech decode reached the GPU gate without an active generation lease."
            )
        }
        activeGenerationCount -= 1

        if decodeActive || activeGenerationCount > 0 || decodeWaiters.isEmpty == false {
            await withCheckedContinuation { continuation in
                decodeWaiters.append(
                    Waiter(id: decodeID, continuation: continuation)
                )
                admitNextDecodeIfPossible()
            }
        } else {
            decodeActive = true
        }

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
              activeGenerationCount: \(activeGenerationCount)
              talkerDecodeOverlapAllowed: false
              freshTalkerConcurrency: 2
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
            decodeActive = false
            admitNextDecodeIfPossible()
            admitWaitingGenerationsIfPossible()
        }

        return try TuringQwenNativeSpeechDecoder.decode(
            codebookRows: codebookRows,
            modelRoot: modelRoot,
            performanceMode: performanceMode
        )
    }

    private func admitNextDecodeIfPossible() {
        guard decodeActive == false,
              activeGenerationCount == 0,
              decodeWaiters.isEmpty == false else {
            return
        }
        let waiter = decodeWaiters.removeFirst()
        decodeActive = true
        waiter.continuation.resume()
    }

    private func admitWaitingGenerationsIfPossible() {
        guard decodeActive == false,
              decodeWaiters.isEmpty,
              generationWaiters.isEmpty == false else {
            return
        }
        let available = Self.maximumConcurrentGenerations - activeGenerationCount
        guard available > 0 else { return }
        let admittedCount = min(available, generationWaiters.count)
        let waiters = Array(generationWaiters.prefix(admittedCount))
        generationWaiters.removeFirst(admittedCount)
        activeGenerationCount += waiters.count
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }
}

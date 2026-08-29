import Foundation

nonisolated enum TuringGeneratedSpeechAnalysisResult: Sendable, Equatable {
    case ready(TuringGeneratedSpeechVisualAnalysis)
    case unavailable(reason: TuringGeneratedSpeechAnalysisUnavailableReason)
}

nonisolated enum TuringGeneratedSpeechAnalysisUnavailableReason: String, Sendable, Equatable {
    case invalidInput
    case cancelled
    case deadlineExceeded
    case analysisFailed
}

nonisolated final class TuringSerialGeneratedSpeechAnalysisWorker: @unchecked Sendable {
    private let queue: DispatchQueue
    private let analyzer: any TuringGeneratedSpeechAnalyzing

    init(
        analyzer: any TuringGeneratedSpeechAnalyzing = TuringGeneratedSpeechAnalyzer(),
        label: String = "com.gravitas.plague.turing.generated-speech-analysis"
    ) {
        self.analyzer = analyzer
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func analyze(
        processedAudio: [Float],
        sampleRate: Int,
        channelCount: Int,
        deadline: ContinuousClock.Instant
    ) async -> TuringGeneratedSpeechAnalysisResult {
        await withCheckedContinuation { continuation in
            queue.async { [analyzer] in
                dispatchPrecondition(condition: .notOnQueue(.main))
                precondition(Thread.isMainThread == false)
                let result: TuringGeneratedSpeechAnalysisResult = autoreleasepool {
                    do {
                        return .ready(try analyzer.analyze(
                            processedAudio: processedAudio,
                            sampleRate: sampleRate,
                            channelCount: channelCount,
                            deadline: deadline
                        ))
                    } catch TuringGeneratedSpeechAnalysisError.cancelled {
                        return .unavailable(reason: .cancelled)
                    } catch TuringGeneratedSpeechAnalysisError.deadlineExceeded {
                        return .unavailable(reason: .deadlineExceeded)
                    } catch TuringGeneratedSpeechAnalysisError.invalidSampleRate,
                            TuringGeneratedSpeechAnalysisError.invalidChannelCount,
                            TuringGeneratedSpeechAnalysisError.emptyAudio,
                            TuringGeneratedSpeechAnalysisError.invalidInterleavedCount {
                        return .unavailable(reason: .invalidInput)
                    } catch {
                        return .unavailable(reason: .analysisFailed)
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }
}

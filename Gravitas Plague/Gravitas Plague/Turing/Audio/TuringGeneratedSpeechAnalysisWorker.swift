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
    case queueCapacityExceeded
    case retainedPCMBudgetExceeded
    case queueDelayExceeded
    case totalLatencyExceeded
    case stale
}

nonisolated struct TuringGeneratedSpeechAnalysisWorkerResult: Sendable {
    let result: TuringGeneratedSpeechAnalysisResult
    let timing: TuringGeneratedSpeechAnalysisTiming
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
        queuedAt: ContinuousClock.Instant,
        policy: TuringGeneratedSpeechAnalysisPolicy,
        cancellation: TuringGeneratedSpeechAnalysisCancellationToken,
        started: @escaping @Sendable (UInt64) -> Void
    ) async -> TuringGeneratedSpeechAnalysisWorkerResult {
        await withCheckedContinuation { continuation in
            queue.async { [analyzer] in
                dispatchPrecondition(condition: .notOnQueue(.main))
                precondition(Thread.isMainThread == false)
                let startedAt = ContinuousClock.now
                let queueDelay = queuedAt.duration(to: startedAt)
                let queueDelayNanoseconds = Self.nanoseconds(queueDelay)
                started(queueDelayNanoseconds)
                let result: TuringGeneratedSpeechAnalysisResult = autoreleasepool {
                    guard queueDelay <= policy.maximumQueueDelay else {
                        return .unavailable(reason: .queueDelayExceeded)
                    }
                    guard !cancellation.isCancelled else {
                        return .unavailable(reason: .cancelled)
                    }
                    let computeDeadline = startedAt.advanced(
                        by: policy.computeBudget(
                            sampleCount: processedAudio.count / max(1, channelCount),
                            sampleRate: sampleRate
                        )
                    )
                    let totalDeadline = queuedAt.advanced(by: policy.maximumTotalLatency)
                    let deadline = min(computeDeadline, totalDeadline)
                    do {
                        return .ready(try analyzer.analyze(
                            processedAudio: processedAudio,
                            sampleRate: sampleRate,
                            channelCount: channelCount,
                            deadline: deadline,
                            cancellationToken: cancellation
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
                let completedAt = ContinuousClock.now
                let timing = TuringGeneratedSpeechAnalysisTiming(
                    queuedAt: queuedAt,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    queueDelayNanoseconds: queueDelayNanoseconds,
                    computeNanoseconds: Self.nanoseconds(startedAt.duration(to: completedAt)),
                    totalLatencyNanoseconds: Self.nanoseconds(queuedAt.duration(to: completedAt))
                )
                let final: TuringGeneratedSpeechAnalysisResult
                if queuedAt.duration(to: completedAt) > policy.maximumTotalLatency,
                   case .ready = result {
                    final = .unavailable(reason: .totalLatencyExceeded)
                } else {
                    final = result
                }
                continuation.resume(returning: .init(result: final, timing: timing))
            }
        }
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanos = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        let product = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !product.overflow else { return .max }
        let sum = product.partialValue.addingReportingOverflow(nanos)
        return sum.overflow ? .max : sum.partialValue
    }
}

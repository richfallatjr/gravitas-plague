import Foundation

nonisolated struct TuringGeneratedSpeechAnalysisBudget: Sendable, Equatable {
    let hardBudget: Duration
    let postFileWriteGrace: Duration

    static let production = TuringGeneratedSpeechAnalysisBudget(
        hardBudget: .milliseconds(40),
        postFileWriteGrace: .milliseconds(4)
    )
}

nonisolated enum TuringGeneratedSpeechAnalysisRace {
    private final class ResolutionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var didResolve = false
        private var continuation: CheckedContinuation<TuringGeneratedSpeechAnalysisResult, Never>?

        init(_ continuation: CheckedContinuation<TuringGeneratedSpeechAnalysisResult, Never>) {
            self.continuation = continuation
        }

        func resolve(_ result: TuringGeneratedSpeechAnalysisResult) {
            let pending: CheckedContinuation<TuringGeneratedSpeechAnalysisResult, Never>?
            lock.lock()
            if didResolve {
                pending = nil
            } else {
                didResolve = true
                pending = continuation
                continuation = nil
            }
            lock.unlock()
            pending?.resume(returning: result)
        }
    }

    static func resolve(
        task: Task<TuringGeneratedSpeechAnalysisResult, Never>,
        grace: Duration
    ) async -> TuringGeneratedSpeechAnalysisResult {
        await withCheckedContinuation { continuation in
            let box = ResolutionBox(continuation)
            Task {
                box.resolve(await task.value)
            }
            Task {
                do {
                    try await ContinuousClock().sleep(for: grace)
                    box.resolve(.unavailable(reason: .deadlineExceeded))
                } catch {
                    box.resolve(.unavailable(reason: .cancelled))
                }
            }
        }
    }
}

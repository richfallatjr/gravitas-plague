import Foundation

nonisolated struct TuringGeneratedSpeechAnalysisPolicy: Sendable, Equatable {
    let minimumComputeBudget: Duration
    let maximumComputeBudget: Duration
    let computeBudgetFraction: Double
    let maximumQueueDelay: Duration
    let maximumTotalLatency: Duration
    let maximumQueuedJobCount: Int
    let maximumRetainedPCMBytes: Int

    static let production = TuringGeneratedSpeechAnalysisPolicy(
        minimumComputeBudget: .milliseconds(150),
        maximumComputeBudget: .milliseconds(800),
        computeBudgetFraction: 0.08,
        maximumQueueDelay: .seconds(1),
        maximumTotalLatency: .seconds(2),
        maximumQueuedJobCount: 2,
        maximumRetainedPCMBytes: 32 * 1024 * 1024
    )

    func computeBudget(sampleCount: Int, sampleRate: Int) -> Duration {
        guard sampleCount > 0, sampleRate > 0 else { return minimumComputeBudget }
        let requested = Duration.seconds(
            Double(sampleCount) / Double(sampleRate) * computeBudgetFraction
        )
        return min(maximumComputeBudget, max(minimumComputeBudget, requested))
    }
}

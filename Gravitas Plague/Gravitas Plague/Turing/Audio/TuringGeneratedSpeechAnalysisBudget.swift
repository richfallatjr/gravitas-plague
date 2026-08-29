import Foundation

nonisolated struct TuringGeneratedSpeechAnalysisPolicy: Sendable, Equatable {
    let minimumComputeBudget: Duration
    let maximumComputeBudget: Duration
    let computeBudgetFraction: Double
    let coldInitializationSoftTarget: Duration
    let coldInitializationHardLimit: Duration
    let warmComputeSoftTarget: Duration
    let maximumQueueDelay: Duration
    let maximumTotalLatency: Duration
    let maximumQueuedJobCount: Int
    let maximumRetainedPCMBytes: Int
    let minimumRemainingAudioForLateJoin: Duration

    static let production = TuringGeneratedSpeechAnalysisPolicy(
        minimumComputeBudget: .milliseconds(750),
        maximumComputeBudget: .seconds(2),
        computeBudgetFraction: 0.15,
        coldInitializationSoftTarget: .milliseconds(350),
        coldInitializationHardLimit: .seconds(1),
        warmComputeSoftTarget: .seconds(1),
        maximumQueueDelay: .seconds(4),
        maximumTotalLatency: .seconds(6),
        maximumQueuedJobCount: 3,
        maximumRetainedPCMBytes: 16 * 1024 * 1024,
        minimumRemainingAudioForLateJoin: .milliseconds(350)
    )

    func computeBudget(sampleCount: Int, sampleRate: Int) -> Duration {
        guard sampleCount > 0, sampleRate > 0 else { return minimumComputeBudget }
        let requested = Duration.seconds(
            Double(sampleCount) / Double(sampleRate) * computeBudgetFraction
        )
        return min(maximumComputeBudget, max(minimumComputeBudget, requested))
    }
}

import Foundation

/// Qualification-only cooperative limits. Does not change production row limits
/// or interrupt in-flight Metal work. The host launcher also enforces a deadline.
public struct TuringQwenPerformanceBudget: Sendable {
    @TaskLocal public static var current: TuringQwenPerformanceBudget?
    let deadline: ContinuousClock.Instant
    public let maximumFootprintMiB: Double

    public init(wallSeconds: Double, maximumFootprintMiB: Double) throws {
        guard wallSeconds.isFinite, (1...180).contains(wallSeconds),
              maximumFootprintMiB.isFinite, (256...6_500).contains(maximumFootprintMiB) else {
            throw TuringQwenNativeError.invalidConfig("Invalid bounded qualification wall/memory limits")
        }
        self.deadline = ContinuousClock.now.advanced(by: .seconds(wallSeconds))
        self.maximumFootprintMiB = maximumFootprintMiB
    }

    public static func check() throws {
        guard let budget = current else { return }
        try Task.checkCancellation()
        guard ContinuousClock.now < budget.deadline else {
            throw TuringQwenNativeError.invalidConfig("Qualification wall-time budget exhausted; not a model failure")
        }
        let footprint = TuringQwenNativeProcessMemoryProbe.snapshot().physFootprintMB
        guard footprint > 0, footprint.isFinite, footprint <= budget.maximumFootprintMiB else {
            throw TuringQwenNativeError.invalidConfig("Qualification footprint budget exhausted: \(footprint) MiB")
        }
    }
}

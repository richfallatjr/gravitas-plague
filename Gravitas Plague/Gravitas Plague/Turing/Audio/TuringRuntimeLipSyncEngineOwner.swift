import Foundation

nonisolated final class TuringRuntimeLipSyncEngineOwner: @unchecked Sendable {
    struct Lease {
        let engine: TuringPocketSphinxEngine
        let coldStartNanoseconds: UInt64?
    }

    private let lock = NSLock()
    private let resourceLocator: TuringRuntimeLipSyncResourceLocator
    private var engine: TuringPocketSphinxEngine?
    private var activeRunID: String?
    private var disabledRunID: String?
    private var disabledFailure: TuringRuntimeLipSyncFailure?

    init(resourceLocator: TuringRuntimeLipSyncResourceLocator) {
        self.resourceLocator = resourceLocator
    }

    func lease(for runID: String) throws -> Lease {
        dispatchPrecondition(condition: .notOnQueue(.main))
        lock.lock()
        defer { lock.unlock() }
        if disabledRunID == runID, let disabledFailure { throw disabledFailure }
        if let engine {
            activeRunID = runID
            return .init(engine: engine, coldStartNanoseconds: nil)
        }
        let start = ContinuousClock.now
        do {
            let resources = try resourceLocator.resolveAndValidate()
            let loaded = try TuringPocketSphinxEngine(resources: resources)
            engine = loaded
            activeRunID = runID
            disabledRunID = nil
            disabledFailure = nil
            return .init(
                engine: loaded,
                coldStartNanoseconds: Self.nanoseconds(start.duration(to: .now))
            )
        } catch let failure as TuringRuntimeLipSyncFailure {
            disabledRunID = runID
            disabledFailure = failure
            throw failure
        } catch {
            let failure = TuringRuntimeLipSyncFailure.engineLoadFailed(
                error.localizedDescription
            )
            disabledRunID = runID
            disabledFailure = failure
            throw failure
        }
    }

    func unload(reason: String) {
        lock.lock()
        engine?.unload()
        engine = nil
        activeRunID = nil
        disabledRunID = nil
        disabledFailure = nil
        lock.unlock()
        print("[TuringRuntimeLipSync] engine unloaded reason=\(reason)")
    }

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return engine != nil
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

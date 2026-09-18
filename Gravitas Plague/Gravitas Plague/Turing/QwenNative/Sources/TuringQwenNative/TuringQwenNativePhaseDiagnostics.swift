import Foundation
import MLX
import OSLog

/// Qualification-only CPU spans and tensor *metadata*, never tensor evaluation.
/// Enable at launch with TURING_QWEN_PHASE_DIAGNOSTICS=1, or override for a
/// bounded benchmark using `$enabled.withValue(true)`. Production defaults off.
/// Enqueue spans may include existing materialization waits, but are NOT GPU
/// completion timings. Use the Metal command-buffer ledger for GPU duration.
public enum TuringQwenNativePhaseDiagnostics {
    @TaskLocal public static var enabled: Bool? = nil
    @TaskLocal static var current: Context?

    private static let startupEnabled =
        ProcessInfo.processInfo.environment["TURING_QWEN_PHASE_DIAGNOSTICS"] == "1"
    private static let log = OSLog(subsystem: "com.gravitas.turing", category: "QwenNativePhases")

    static func makeContext(
        runID: @autoclosure () -> String,
        lane: @autoclosure () -> String,
        segmentIndex: Int
    ) -> Context? {
        guard enabled ?? startupEnabled else { return nil }
        return Context(runID: runID(), lane: lane(), segmentIndex: segmentIndex)
    }

    static func begin(
        _ phase: StaticString,
        context: Context? = current,
        detail: @autoclosure () -> String = ""
    ) -> Span? {
        guard let context, context.limiter.reserveInterval(phase: String(describing: phase)) else {
            return nil
        }
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: phase, signpostID: id,
                    "CPU scope (not GPU completion) run=%{public}@ lane=%{public}@ segment=%d %{public}@",
                    context.runID, context.lane, context.segmentIndex, detail())
        return Span(id: id, phase: phase)
    }

    static func end(_ span: Span?) {
        guard let span else { return }
        os_signpost(.end, log: log, name: span.phase, signpostID: span.id)
    }

    static func measure<R>(
        _ phase: StaticString,
        context: Context? = current,
        detail: @autoclosure () -> String = "",
        operation: () throws -> R
    ) rethrows -> R {
        let span = begin(phase, context: context, detail: detail())
        defer { end(span) }
        return try operation()
    }

    static func event(
        _ name: StaticString,
        context: Context? = current,
        detail: @autoclosure () -> String = ""
    ) {
        guard let context, context.limiter.reserveInterval(phase: String(describing: name)) else {
            return
        }
        os_signpost(.event, log: log, name: name, signpostID: OSSignpostID(log: log),
                    "run=%{public}@ lane=%{public}@ segment=%d %{public}@",
                    context.runID, context.lane, context.segmentIndex, detail())
    }

    /// Accessing shape/dtype does not materialize a lazy MLX array. The closure
    /// is not called when diagnostics are off or the bounded record cap is full.
    static func tensor(_ role: StaticString, _ array: @autoclosure () -> MLXArray) {
        guard let context = current else { return }
        let roleName = String(describing: role)
        guard context.limiter.reserveInspection(role: roleName) else { return }
        let value = array()
        metadata(role: roleName, shape: value.shape, dtype: String(describing: value.dtype))
    }

    static func metadata(role: String, shape: [Int], dtype: String) {
        guard let context = current,
              context.limiter.reserveMetadata(role: role, shape: shape, dtype: dtype) else { return }
        os_signpost(.event, log: log, name: "TensorMetadata", signpostID: OSSignpostID(log: log),
                    "run=%{public}@ lane=%{public}@ segment=%d role=%{public}@ shape=%{public}@ dtype=%{public}@",
                    context.runID, context.lane, context.segmentIndex, role,
                    shape.map(String.init).joined(separator: "x"), dtype)
    }

    struct Span {
        let id: OSSignpostID
        let phase: StaticString
    }

    final class Context: @unchecked Sendable {
        let runID: String
        let lane: String
        let segmentIndex: Int
        let limiter = Limiter()

        init(runID: String, lane: String, segmentIndex: Int) {
            self.runID = runID
            self.lane = lane
            self.segmentIndex = segmentIndex
        }
    }

    /// Separate from MLX and signposts so disabled behavior and boundedness are
    /// unit-testable without allocating a model or initializing a Metal device.
    final class Limiter: @unchecked Sendable {
        private let lock = NSLock()
        private var intervalCount = 0
        private var phases: [String: Int] = [:]
        private var metadataCount = 0
        private var metadataByRole: [String: Set<String>] = [:]
        private var inspectionsByRole: [String: Int] = [:]
        private let maximumIntervals: Int
        private let maximumPerPhase: Int
        private let maximumMetadata: Int
        private let maximumShapesPerRole: Int

        init(maximumIntervals: Int = 512, maximumPerPhase: Int = 32,
             maximumMetadata: Int = 128, maximumShapesPerRole: Int = 4) {
            self.maximumIntervals = maximumIntervals
            self.maximumPerPhase = maximumPerPhase
            self.maximumMetadata = maximumMetadata
            self.maximumShapesPerRole = maximumShapesPerRole
        }

        func reserveInterval(phase: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard intervalCount < maximumIntervals,
                  phases[phase, default: 0] < maximumPerPhase else { return false }
            intervalCount += 1
            phases[phase, default: 0] += 1
            return true
        }

        func reserveInspection(role: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard metadataCount < maximumMetadata,
                  inspectionsByRole.count < maximumMetadata || inspectionsByRole[role] != nil,
                  inspectionsByRole[role, default: 0] < 16,
                  metadataByRole[role, default: []].count < maximumShapesPerRole else { return false }
            inspectionsByRole[role, default: 0] += 1
            return true
        }

        func reserveMetadata(role: String, shape: [Int], dtype: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard metadataCount < maximumMetadata,
                  metadataByRole[role, default: []].count < maximumShapesPerRole else { return false }
            let signature = "\(dtype):\(shape)"
            guard metadataByRole[role, default: []].insert(signature).inserted else { return false }
            metadataCount += 1
            return true
        }
    }
}

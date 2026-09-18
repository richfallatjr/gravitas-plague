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
    /// Explicit benchmark ownership; absent in normal production execution.
    /// Installing a recorder does not enable diagnostics by itself.
    @TaskLocal public static var recordingSession: RecordingSession?
    @TaskLocal static var current: Context?

    private static let startupEnabled =
        ProcessInfo.processInfo.environment["TURING_QWEN_PHASE_DIAGNOSTICS"] == "1"
    private static let log = OSLog(subsystem: "com.gravitas.turing", category: "QwenNativePhases")

    public static var isEnabled: Bool { enabled ?? startupEnabled }

    static func makeContext(
        runID: @autoclosure () -> String,
        lane: @autoclosure () -> String,
        segmentIndex: Int
    ) -> Context? {
        guard isEnabled else { return nil }
        return Context(runID: runID(), lane: lane(), segmentIndex: segmentIndex)
    }

    static func begin(
        _ phase: StaticString,
        context: Context? = current,
        detail: @autoclosure () -> String = ""
    ) -> Span? {
        guard let context else { return nil }
        let phaseName = String(describing: phase)
        guard context.limiter.reserveInterval(phase: phaseName) else {
            context.recording?.recordDroppedScope()
            return nil
        }
        let detailValue = detail()
        let recordIndex = context.recording?.beginScope(
            phase: phaseName, context: context.recordContext, detail: detailValue)
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: phase, signpostID: id,
                    "CPU scope (not GPU completion) run=%{public}@ lane=%{public}@ segment=%d %{public}@",
                    context.runID, context.lane, context.segmentIndex, detailValue)
        return Span(id: id, phase: phase, recording: context.recording, recordIndex: recordIndex)
    }

    static func end(_ span: Span?) {
        guard let span else { return }
        if let recordIndex = span.recordIndex {
            span.recording?.endScope(recordIndex)
        }
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
        guard let context else { return }
        let eventName = String(describing: name)
        guard context.limiter.reserveInterval(phase: eventName) else {
            context.recording?.recordDroppedEvent()
            return
        }
        let detailValue = detail()
        context.recording?.recordEvent(name: eventName, context: context.recordContext, detail: detailValue)
        os_signpost(.event, log: log, name: name, signpostID: OSSignpostID(log: log),
                    "run=%{public}@ lane=%{public}@ segment=%d %{public}@",
                    context.runID, context.lane, context.segmentIndex, detailValue)
    }

    /// Accessing shape/dtype does not materialize a lazy MLX array. The closure
    /// is not called when diagnostics are off or the context inspection cap is full.
    static func tensor(_ role: StaticString, _ array: @autoclosure () -> MLXArray) {
        guard let context = current else { return }
        let roleName = String(describing: role)
        guard context.limiter.reserveInspection(role: roleName) else {
            context.recording?.recordSuppressedMetadata(.inspectionLimit)
            return
        }
        let value = array()
        metadata(role: roleName, shape: value.shape, dtype: String(describing: value.dtype))
    }

    static func metadata(role: String, shape: [Int], dtype: String) {
        guard let context = current else { return }
        let disposition = context.limiter.reserveMetadataResult(role: role, shape: shape, dtype: dtype)
        guard disposition == .accepted else {
            context.recording?.recordSuppressedMetadata(disposition)
            return
        }
        context.recording?.recordMetadata(context: context.recordContext, role: role, shape: shape, dtype: dtype)
        os_signpost(.event, log: log, name: "TensorMetadata", signpostID: OSSignpostID(log: log),
                    "run=%{public}@ lane=%{public}@ segment=%d role=%{public}@ shape=%{public}@ dtype=%{public}@",
                    context.runID, context.lane, context.segmentIndex, role,
                    shape.map(String.init).joined(separator: "x"), dtype)
    }

    struct Span {
        let id: OSSignpostID
        let phase: StaticString
        let recording: RecordingSession?
        let recordIndex: Int?
    }

    final class Context: @unchecked Sendable {
        let runID: String
        let lane: String
        let segmentIndex: Int
        let limiter = Limiter()
        let recording: RecordingSession?

        var recordContext: RecordContext {
            RecordContext(runID: runID, lane: lane, segmentIndex: segmentIndex)
        }

        init(runID: String, lane: String, segmentIndex: Int) {
            self.runID = runID
            self.lane = lane
            self.segmentIndex = segmentIndex
            self.recording = recordingSession
        }
    }

    public struct RecordContext: Codable, Sendable, Equatable {
        public let runID: String
        public let lane: String
        public let segmentIndex: Int
    }

    public struct ScopeRecord: Codable, Sendable, Equatable {
        public let context: RecordContext
        public let phase: String
        public let detail: String
        public let detailTruncated: Bool
        public let beginNanoseconds: UInt64
        public internal(set) var endNanoseconds: UInt64?
        public internal(set) var durationNanoseconds: UInt64?
    }

    public struct MetadataRecord: Codable, Sendable, Equatable {
        public let context: RecordContext
        public let timestampNanoseconds: UInt64
        public let role: String
        public let shape: [Int]
        public let dtype: String
    }

    public struct EventRecord: Codable, Sendable, Equatable {
        public let context: RecordContext
        public let timestampNanoseconds: UInt64
        public let name: String
        public let detail: String
        public let detailTruncated: Bool
    }

    /// A bounded sample of inclusive elapsed CPU scopes. Nested and concurrent
    /// intervals overlap: their sums are neither CPU utilization nor GPU time.
    public struct Report: Codable, Sendable {
        public let schemaVersion: Int
        public let clockBasis: String
        public let durationSemantics: String
        public let maximumScopes: Int
        public let maximumMetadata: Int
        public let maximumEvents: Int
        public let maximumDetailCharacters: Int
        public let maximumIntervalsPerContext: Int
        public let maximumIntervalsPerPhasePerContext: Int
        public let maximumMetadataPerContext: Int
        public let maximumShapesPerRolePerContext: Int
        public let maximumInspectionsPerRolePerContext: Int
        public let scopes: [ScopeRecord]
        public let metadata: [MetadataRecord]
        public let events: [EventRecord]
        public let scopeAttemptCount: Int
        public let droppedScopeCount: Int
        public let pendingScopeCount: Int
        public let invalidScopeTimestampCount: Int
        public let metadataAttemptCount: Int
        public let droppedMetadataCount: Int
        public let duplicateMetadataCount: Int
        public let inspectionLimitDropCount: Int
        public let eventAttemptCount: Int
        public let droppedEventCount: Int
    }

    /// All mutable report state belongs to this explicitly scoped session.
    /// A lock permits inherited task-local use by both Fresh2 workers. No file
    /// output, tensor evaluation, GPU synchronization or process-global ledger.
    public final class RecordingSession: @unchecked Sendable {
        private let lock = NSLock()
        private let origin = ContinuousClock.now
        private let maximumScopes: Int
        private let maximumMetadata: Int
        private let maximumEvents: Int
        private let maximumDetailCharacters = 512
        private var scopes: [ScopeRecord] = []
        private var metadata: [MetadataRecord] = []
        private var events: [EventRecord] = []
        private var scopeAttemptCount = 0
        private var droppedScopeCount = 0
        private var invalidScopeTimestampCount = 0
        private var metadataAttemptCount = 0
        private var droppedMetadataCount = 0
        private var duplicateMetadataCount = 0
        private var inspectionLimitDropCount = 0
        private var eventAttemptCount = 0
        private var droppedEventCount = 0

        public init(maximumScopes: Int = 8_192, maximumMetadata: Int = 2_048,
                    maximumEvents: Int = 2_048) {
            self.maximumScopes = max(0, maximumScopes)
            self.maximumMetadata = max(0, maximumMetadata)
            self.maximumEvents = max(0, maximumEvents)
        }

        private func nowNanoseconds() -> UInt64 {
            let elapsed = origin.duration(to: .now).components
            return UInt64(max(0, elapsed.seconds * 1_000_000_000 + elapsed.attoseconds / 1_000_000_000))
        }

        // Explicit timestamps are internal deterministic-test hooks; production
        // uses the session's ContinuousClock origin at the existing boundaries.
        func beginScope(phase: String, context: RecordContext, detail: String,
                        timestampNanoseconds: UInt64? = nil) -> Int? {
            let timestamp = timestampNanoseconds ?? nowNanoseconds()
            lock.lock()
            defer { lock.unlock() }
            scopeAttemptCount += 1
            guard scopes.count < maximumScopes else {
                droppedScopeCount += 1
                return nil
            }
            let index = scopes.count
            let boundedDetail = String(detail.prefix(maximumDetailCharacters))
            scopes.append(ScopeRecord(context: context, phase: phase,
                                      detail: boundedDetail, detailTruncated: boundedDetail != detail,
                                      beginNanoseconds: timestamp))
            return index
        }

        func endScope(_ index: Int, timestampNanoseconds: UInt64? = nil) {
            let timestamp = timestampNanoseconds ?? nowNanoseconds()
            lock.lock()
            defer { lock.unlock() }
            guard scopes.indices.contains(index), scopes[index].endNanoseconds == nil else { return }
            scopes[index].endNanoseconds = timestamp
            if timestamp >= scopes[index].beginNanoseconds {
                scopes[index].durationNanoseconds = timestamp - scopes[index].beginNanoseconds
            } else {
                invalidScopeTimestampCount += 1
            }
        }

        func recordDroppedScope() {
            lock.lock()
            defer { lock.unlock() }
            scopeAttemptCount += 1
            droppedScopeCount += 1
        }

        func recordMetadata(context: RecordContext, role: String, shape: [Int], dtype: String,
                            timestampNanoseconds: UInt64? = nil) {
            let timestamp = timestampNanoseconds ?? nowNanoseconds()
            lock.lock()
            defer { lock.unlock() }
            metadataAttemptCount += 1
            guard metadata.count < maximumMetadata else {
                droppedMetadataCount += 1
                return
            }
            metadata.append(MetadataRecord(context: context, timestampNanoseconds: timestamp,
                                           role: role, shape: shape, dtype: dtype))
        }

        func recordSuppressedMetadata(_ disposition: MetadataDisposition) {
            lock.lock()
            defer { lock.unlock() }
            metadataAttemptCount += 1
            if disposition == .duplicate {
                duplicateMetadataCount += 1
            } else {
                droppedMetadataCount += 1
                if disposition == .inspectionLimit { inspectionLimitDropCount += 1 }
            }
        }

        func recordEvent(name: String, context: RecordContext, detail: String,
                         timestampNanoseconds: UInt64? = nil) {
            let timestamp = timestampNanoseconds ?? nowNanoseconds()
            lock.lock()
            defer { lock.unlock() }
            eventAttemptCount += 1
            guard events.count < maximumEvents else {
                droppedEventCount += 1
                return
            }
            let boundedDetail = String(detail.prefix(maximumDetailCharacters))
            events.append(EventRecord(context: context, timestampNanoseconds: timestamp,
                                      name: name, detail: boundedDetail,
                                      detailTruncated: boundedDetail != detail))
        }

        func recordDroppedEvent() {
            lock.lock()
            defer { lock.unlock() }
            eventAttemptCount += 1
            droppedEventCount += 1
        }

        public func snapshot() -> Report {
            lock.lock()
            defer { lock.unlock() }
            return Report(
                schemaVersion: 1, clockBasis: "ContinuousClock relative to recording session origin; nanoseconds",
                durationSemantics: "Inclusive elapsed CPU scopes including existing evaluation/waits; nested and concurrent scopes overlap. Not CPU time, GPU time, GPU completion attribution, or additive phase costs. Capped diagnostic samples, not complete-run totals.",
                maximumScopes: maximumScopes, maximumMetadata: maximumMetadata, maximumEvents: maximumEvents,
                maximumDetailCharacters: maximumDetailCharacters,
                maximumIntervalsPerContext: 512, maximumIntervalsPerPhasePerContext: 32,
                maximumMetadataPerContext: 128, maximumShapesPerRolePerContext: 4,
                maximumInspectionsPerRolePerContext: 16,
                scopes: scopes, metadata: metadata, events: events,
                scopeAttemptCount: scopeAttemptCount, droppedScopeCount: droppedScopeCount,
                pendingScopeCount: scopes.filter { $0.endNanoseconds == nil }.count,
                invalidScopeTimestampCount: invalidScopeTimestampCount,
                metadataAttemptCount: metadataAttemptCount, droppedMetadataCount: droppedMetadataCount,
                duplicateMetadataCount: duplicateMetadataCount, inspectionLimitDropCount: inspectionLimitDropCount,
                eventAttemptCount: eventAttemptCount, droppedEventCount: droppedEventCount)
        }
    }

    enum MetadataDisposition: Equatable { case accepted, duplicate, metadataLimit, inspectionLimit }

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
            reserveMetadataResult(role: role, shape: shape, dtype: dtype) == .accepted
        }

        func reserveMetadataResult(role: String, shape: [Int], dtype: String) -> MetadataDisposition {
            lock.lock()
            defer { lock.unlock() }
            guard metadataCount < maximumMetadata,
                  metadataByRole[role, default: []].count < maximumShapesPerRole else { return .metadataLimit }
            let signature = "\(dtype):\(shape)"
            guard metadataByRole[role, default: []].insert(signature).inserted else { return .duplicate }
            metadataCount += 1
            return .accepted
        }
    }
}

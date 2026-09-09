import Foundation

/// Stage 4 is opt-in until incremental decoder parity and queue economics are
/// qualified on device. The production default remains the canonical
/// whole-segment render/decode path.
public struct TuringQwenNativeExperimentalStreamingConfiguration:
    Sendable,
    Equatable
{
    public enum Mode: String, Sendable, Equatable {
        case disabled
        case qualificationGrowingPrefix
    }

    public static let generatedRowsPerWindow = 8
    public static let samplesPerGeneratedRow = 1_920
    public static let outputSampleRate = 24_000
    public static let generatedAudioSecondsPerRow = 0.08
    public static let generatedAudioSecondsPerWindow = 0.64

    public static let disabled = Self()
    public static let qualificationGrowingPrefix = Self(
        mode: .qualificationGrowingPrefix
    )

    public let mode: Mode

    public init(mode: Mode = .disabled) {
        self.mode = mode
    }

    public var isEnabled: Bool {
        mode != .disabled
    }

    func validate(eventSinkIsPresent: Bool) throws {
        guard isEnabled == eventSinkIsPresent else {
            throw TuringQwenNativeError.invalidConfig(
                isEnabled
                    ? "Experimental PCM streaming requires an incremental codebook event sink."
                    : "An incremental codebook event sink requires explicit experimental streaming activation."
            )
        }
    }
}

public struct TuringQwenNativeIncrementalCodebookStreamIdentity:
    Hashable,
    Sendable
{
    public let streamID: UUID
    public let runID: String
    public let segmentIndex: Int
    public let instanceID: TuringQwenNativeFreshInstanceID
    public let voiceID: String
    public let recoveryGeneration: TuringQwenNativeRecoveryGeneration

    public init(
        streamID: UUID = UUID(),
        runID: String,
        segmentIndex: Int,
        instanceID: TuringQwenNativeFreshInstanceID,
        voiceID: String,
        recoveryGeneration: TuringQwenNativeRecoveryGeneration = .initial
    ) {
        self.streamID = streamID
        self.runID = runID
        self.segmentIndex = segmentIndex
        self.instanceID = instanceID
        self.voiceID = voiceID
        self.recoveryGeneration = recoveryGeneration
    }
}

/// A self-contained growing-prefix snapshot. `newGeneratedRowRange` is the
/// only newly committed portion; the complete prefix is included so the
/// qualification decoder never observes mutable generation storage.
public struct TuringQwenNativeIncrementalCodebookWindow:
    Sendable,
    Equatable
{
    public let identity: TuringQwenNativeIncrementalCodebookStreamIdentity
    public let newGeneratedRowRange: Range<Int>
    public let referenceRows: [[Int]]
    public let generatedPrefixRows: [[Int]]
    public let codebookCount: Int
    public let performanceMode: TuringQwenNativePerformanceMode

    public init(
        identity: TuringQwenNativeIncrementalCodebookStreamIdentity,
        newGeneratedRowRange: Range<Int>,
        referenceRows: [[Int]],
        generatedPrefixRows: [[Int]],
        codebookCount: Int,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws {
        guard codebookCount > 0,
              newGeneratedRowRange.lowerBound >= 0,
              newGeneratedRowRange.isEmpty == false,
              newGeneratedRowRange.count <=
                TuringQwenNativeExperimentalStreamingConfiguration
                    .generatedRowsPerWindow,
              newGeneratedRowRange.upperBound == generatedPrefixRows.count,
              referenceRows.allSatisfy({ $0.count == codebookCount }),
              generatedPrefixRows.allSatisfy({ $0.count == codebookCount }) else {
            throw TuringQwenNativeError.invalidConfig(
                "Incremental codebook window has invalid row bounds or width."
            )
        }

        self.identity = identity
        self.newGeneratedRowRange = newGeneratedRowRange
        self.referenceRows = referenceRows
        self.generatedPrefixRows = generatedPrefixRows
        self.codebookCount = codebookCount
        self.performanceMode = performanceMode
    }
}

public struct TuringQwenNativeIncrementalCodebookTerminal:
    Sendable,
    Equatable
{
    public let identity: TuringQwenNativeIncrementalCodebookStreamIdentity
    public let generatedRowCount: Int
    public let reachedEOS: Bool

    public init(
        identity: TuringQwenNativeIncrementalCodebookStreamIdentity,
        generatedRowCount: Int,
        reachedEOS: Bool
    ) {
        self.identity = identity
        self.generatedRowCount = generatedRowCount
        self.reachedEOS = reachedEOS
    }
}

public enum TuringQwenNativeIncrementalCodebookEvent: Sendable, Equatable {
    case window(TuringQwenNativeIncrementalCodebookWindow)
    case finished(TuringQwenNativeIncrementalCodebookTerminal)
    case failed(
        identity: TuringQwenNativeIncrementalCodebookStreamIdentity,
        message: String
    )
}

/// `yield` never suspends the Qwen row loop. The unbounded event stream is
/// acceptable here because each segment is intrinsically capped by
/// `maxNewRows`; the later PCM transport owns the bounded-seconds policy.
public struct TuringQwenNativeIncrementalCodebookEventSink: Sendable {
    private final class Lifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var remainingTerminalCount: Int
        private var terminalStreamIDs = Set<UUID>()
        private var isTerminated = false

        init(expectedTerminalCount: Int) {
            precondition(expectedTerminalCount > 0)
            remainingTerminalCount = expectedTerminalCount
        }

        func accept(
            _ event: TuringQwenNativeIncrementalCodebookEvent
        ) -> (shouldYield: Bool, shouldFinish: Bool) {
            lock.lock()
            defer { lock.unlock() }

            guard !isTerminated else {
                return (false, false)
            }

            let identity: TuringQwenNativeIncrementalCodebookStreamIdentity
            let isTerminal: Bool
            switch event {
            case .window(let window):
                identity = window.identity
                isTerminal = false
            case .finished(let terminal):
                identity = terminal.identity
                isTerminal = true
            case .failed(let failedIdentity, _):
                identity = failedIdentity
                isTerminal = true
            }

            // A render owns exactly one terminal. Ignore duplicate terminals and
            // any events that arrive after that render has terminated without
            // letting it close a stream shared by sibling renders.
            guard !terminalStreamIDs.contains(identity.streamID) else {
                return (false, false)
            }
            guard isTerminal else {
                return (true, false)
            }

            terminalStreamIDs.insert(identity.streamID)
            remainingTerminalCount -= 1
            if remainingTerminalCount == 0 {
                isTerminated = true
                return (true, true)
            }
            return (true, false)
        }

        func cancel() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isTerminated else { return false }
            isTerminated = true
            return true
        }
    }

    private let continuation:
        AsyncStream<TuringQwenNativeIncrementalCodebookEvent>.Continuation
    private let lifecycle: Lifecycle

    private init(
        continuation:
            AsyncStream<TuringQwenNativeIncrementalCodebookEvent>.Continuation,
        lifecycle: Lifecycle
    ) {
        self.continuation = continuation
        self.lifecycle = lifecycle
    }

    /// Creates a stream owned by one render. Its first unique terminal event is
    /// yielded and then closes iteration, so a consumer cannot wait forever.
    public static func makePerRenderStream() -> (
        events: AsyncStream<TuringQwenNativeIncrementalCodebookEvent>,
        sink: Self
    ) {
        makeStream(expectedTerminalCount: 1)
    }

    /// Creates a deliberately shared collector. Exactly this many distinct
    /// render stream identities must terminate before iteration closes; one
    /// render can never finish the collector on behalf of its siblings.
    public static func makeSharedStream(
        expectedTerminalCount: Int
    ) throws -> (
        events: AsyncStream<TuringQwenNativeIncrementalCodebookEvent>,
        sink: Self
    ) {
        guard expectedTerminalCount > 0 else {
            throw TuringQwenNativeError.invalidConfig(
                "Incremental codebook stream must expect at least one terminal."
            )
        }
        return makeStream(expectedTerminalCount: expectedTerminalCount)
    }

    private static func makeStream(
        expectedTerminalCount: Int
    ) -> (
        events: AsyncStream<TuringQwenNativeIncrementalCodebookEvent>,
        sink: Self
    ) {
        // The number of events remains intrinsically bounded by each render's
        // maxNewRows. `.unbounded` here prevents silent window loss; lifecycle
        // termination above bounds how long the collector can remain open.
        let pair = AsyncStream<TuringQwenNativeIncrementalCodebookEvent>
            .makeStream(bufferingPolicy: .unbounded)
        let lifecycle = Lifecycle(
            expectedTerminalCount: expectedTerminalCount
        )
        pair.continuation.onTermination = { @Sendable _ in
            _ = lifecycle.cancel()
        }
        return (
            events: pair.stream,
            sink: Self(
                continuation: pair.continuation,
                lifecycle: lifecycle
            )
        )
    }

    public func yield(_ event: TuringQwenNativeIncrementalCodebookEvent) {
        let decision = lifecycle.accept(event)
        guard decision.shouldYield else { return }
        continuation.yield(event)
        if decision.shouldFinish {
            continuation.finish()
        }
    }

    /// Explicit owner cancellation. Normal completion is terminal-event driven.
    public func cancel() {
        if lifecycle.cancel() {
            continuation.finish()
        }
    }
}

struct TuringQwenNativeIncrementalCodebookWindowEmitter {
    private let identity: TuringQwenNativeIncrementalCodebookStreamIdentity
    private let referenceRows: [[Int]]
    private let codebookCount: Int
    private let performanceMode: TuringQwenNativePerformanceMode
    private let sink: TuringQwenNativeIncrementalCodebookEventSink
    private var generatedPrefixRows: [[Int]] = []
    private var emittedGeneratedRowCount = 0

    init(
        identity: TuringQwenNativeIncrementalCodebookStreamIdentity,
        referenceRows: [[Int]],
        codebookCount: Int,
        performanceMode: TuringQwenNativePerformanceMode,
        sink: TuringQwenNativeIncrementalCodebookEventSink
    ) throws {
        guard codebookCount > 0,
              referenceRows.allSatisfy({ $0.count == codebookCount }) else {
            throw TuringQwenNativeError.invalidConfig(
                "Incremental codebook emitter received invalid reference rows."
            )
        }
        self.identity = identity
        self.referenceRows = referenceRows
        self.codebookCount = codebookCount
        self.performanceMode = performanceMode
        self.sink = sink
    }

    mutating func commit(_ row: [Int]) throws {
        guard row.count == codebookCount else {
            throw TuringQwenNativeError.invalidConfig(
                "Incremental codebook row width does not match the stream."
            )
        }
        generatedPrefixRows.append(row)
        if generatedPrefixRows.count - emittedGeneratedRowCount ==
            TuringQwenNativeExperimentalStreamingConfiguration
                .generatedRowsPerWindow {
            try emitPendingRows()
        }
    }

    mutating func flushFinalPartialWindow() throws {
        guard emittedGeneratedRowCount < generatedPrefixRows.count else {
            return
        }
        try emitPendingRows()
    }

    private mutating func emitPendingRows() throws {
        let range = emittedGeneratedRowCount..<generatedPrefixRows.count
        let window = try TuringQwenNativeIncrementalCodebookWindow(
            identity: identity,
            newGeneratedRowRange: range,
            referenceRows: referenceRows,
            generatedPrefixRows: generatedPrefixRows,
            codebookCount: codebookCount,
            performanceMode: performanceMode
        )
        sink.yield(.window(window))
        emittedGeneratedRowCount = generatedPrefixRows.count
    }
}

public struct TuringQwenNativeGrowingPrefixDecodePlan: Sendable, Equatable {
    public let rowsForDecode: [[Int]]
    public let newGeneratedRowRange: Range<Int>
    public let fullDecodeSampleRange: Range<Int>
    public let generatedOutputSampleRange: Range<Int>

    public static func make(
        window: TuringQwenNativeIncrementalCodebookWindow,
        previouslyEmittedGeneratedPrefixRows: [[Int]]
    ) throws -> Self {
        let previouslyEmittedGeneratedRowCount =
            previouslyEmittedGeneratedPrefixRows.count
        guard previouslyEmittedGeneratedPrefixRows.allSatisfy({
                  $0.count == window.codebookCount
              }),
              window.newGeneratedRowRange.lowerBound ==
                previouslyEmittedGeneratedRowCount,
              Array(
                  window.generatedPrefixRows.prefix(
                      previouslyEmittedGeneratedRowCount
                  )
              ) == previouslyEmittedGeneratedPrefixRows else {
            throw TuringQwenNativeError.invalidConfig(
                "Incremental codebook window is duplicate, rewritten, or out of order."
            )
        }

        let samplesPerRow =
            TuringQwenNativeExperimentalStreamingConfiguration
                .samplesPerGeneratedRow
        let referenceSampleCount = window.referenceRows.count * samplesPerRow
        let generatedLower =
            window.newGeneratedRowRange.lowerBound * samplesPerRow
        let generatedUpper =
            window.newGeneratedRowRange.upperBound * samplesPerRow
        let fullDecodeSampleRange = Range(
            uncheckedBounds: (
                lower: referenceSampleCount + generatedLower,
                upper: referenceSampleCount + generatedUpper
            )
        )

        return Self(
            rowsForDecode:
                window.referenceRows + window.generatedPrefixRows,
            newGeneratedRowRange: window.newGeneratedRowRange,
            fullDecodeSampleRange: fullDecodeSampleRange,
            generatedOutputSampleRange: generatedLower..<generatedUpper
        )
    }
}

public struct TuringQwenNativeStreamingQueueEconomics:
    Sendable,
    Equatable
{
    public let startupRowCount: Int
    public let totalGeneratedRowCount: Int
    public let generatedRowsPerWindow: Int
    public let emittedCumulativeRowCounts: [Int]
    public let isStartupEmissionBoundary: Bool
    public let observedSecondsPerRow: Double
    public let bufferedAudioSeconds: Double
    public let remainingGenerationSeconds: Double
    public let audioAppendedBeforeFinalRowSeconds: Double
    public let firstArrivalSurplusSeconds: Double
    public let preFinalArrivalSurplusSeconds: Double
    public let optimisticSurplusSeconds: Double
    public let maximumSustainableSecondsPerRow: Double
    public let requiredGenerationRowsPerSecond: Double
    public let minimumPlaybackStartupRowCount: Int
    public let minimumStreamingStartupRowCount: Int?
    public let beginsBeforeGenerationCompletes: Bool
    public let canAvoidUnderrunOptimistically: Bool
    public let qualifiesForExperimentalPlaybackActivation: Bool
}

/// This is deliberately optimistic: decoder time, cadence variance, and GPU
/// interference are zero. A failure here is therefore a hard no-go for actual
/// playback activation, not merely a warning. For `B` startup rows, `N` total
/// rows, window size `W`, row audio `a`, and observed generation cadence `c`,
/// PCM arrives only at `W`, `2W`, ... and the final partial window at `N`.
/// Before each event `E`, survival requires the audio published by the prior
/// event `P` to cover generation since startup: `P*a >= (E-B)*c`.
public enum TuringQwenNativeStreamingQueueEconomicsGate {
    public static let generatedAudioSecondsPerRow = 0.08

    public static func assess(
        startupRowCount: Int,
        totalGeneratedRowCount: Int,
        observedSecondsPerRow: Double,
        generatedRowsPerWindow: Int =
            TuringQwenNativeExperimentalStreamingConfiguration
                .generatedRowsPerWindow
    ) throws -> TuringQwenNativeStreamingQueueEconomics {
        guard totalGeneratedRowCount > 0,
              startupRowCount > 0,
              startupRowCount <= totalGeneratedRowCount,
              generatedRowsPerWindow > 0,
              observedSecondsPerRow.isFinite,
              observedSecondsPerRow >= 0 else {
            throw TuringQwenNativeError.invalidConfig(
                "Streaming queue economics received invalid row counts or cadence."
            )
        }

        let emittedCumulativeRowCounts = emissionRowCounts(
            totalGeneratedRowCount: totalGeneratedRowCount,
            generatedRowsPerWindow: generatedRowsPerWindow
        )
        let streamingStartupRows = emittedCumulativeRowCounts.dropLast()
        let minimumStreamingStartupRowCount = streamingStartupRows.first {
            survivesOptimistically(
                startupRowCount: $0,
                totalGeneratedRowCount: totalGeneratedRowCount,
                observedSecondsPerRow: observedSecondsPerRow,
                generatedRowsPerWindow: generatedRowsPerWindow
            )
        }
        let minimumPlaybackStartupRowCount =
            emittedCumulativeRowCounts.first {
                survivesOptimistically(
                    startupRowCount: $0,
                    totalGeneratedRowCount: totalGeneratedRowCount,
                    observedSecondsPerRow: observedSecondsPerRow,
                    generatedRowsPerWindow: generatedRowsPerWindow
                )
            } ?? totalGeneratedRowCount
        let isStartupEmissionBoundary =
            emittedCumulativeRowCounts.contains(startupRowCount)
        let remainingRowCount = totalGeneratedRowCount - startupRowCount
        let bufferedAudioSeconds =
            Double(startupRowCount) * generatedAudioSecondsPerRow
        let remainingGenerationSeconds =
            Double(remainingRowCount) * observedSecondsPerRow
        let laterEmissionRows = emittedCumulativeRowCounts.filter {
            $0 > startupRowCount
        }
        let priorToFinalEmissionRowCount =
            laterEmissionRows.count > 1
                ? laterEmissionRows[laterEmissionRows.count - 2]
                : startupRowCount
        let audioAppendedBeforeFinalRowSeconds = Double(
            max(priorToFinalEmissionRowCount - startupRowCount, 0)
        ) * generatedAudioSecondsPerRow
        let firstArrivalSurplusSeconds: Double
        let preFinalArrivalSurplusSeconds: Double
        let optimisticSurplusSeconds: Double
        let maximumSustainableSecondsPerRow: Double
        if remainingRowCount == 0 && isStartupEmissionBoundary {
            firstArrivalSurplusSeconds = bufferedAudioSeconds
            preFinalArrivalSurplusSeconds = bufferedAudioSeconds
            optimisticSurplusSeconds = bufferedAudioSeconds
            maximumSustainableSecondsPerRow = .infinity
        } else {
            let firstLaterEmissionRow = laterEmissionRows.first ??
                totalGeneratedRowCount
            firstArrivalSurplusSeconds = bufferedAudioSeconds -
                Double(firstLaterEmissionRow - startupRowCount) *
                observedSecondsPerRow
            preFinalArrivalSurplusSeconds =
                bufferedAudioSeconds +
                audioAppendedBeforeFinalRowSeconds -
                remainingGenerationSeconds
            let eventSurpluses = arrivalSurpluses(
                startupRowCount: startupRowCount,
                emittedCumulativeRowCounts: emittedCumulativeRowCounts,
                observedSecondsPerRow: observedSecondsPerRow
            )
            optimisticSurplusSeconds = eventSurpluses.min() ??
                -Double.greatestFiniteMagnitude
            maximumSustainableSecondsPerRow =
                isStartupEmissionBoundary
                    ? maximumSustainableCadence(
                        startupRowCount: startupRowCount,
                        emittedCumulativeRowCounts:
                            emittedCumulativeRowCounts
                    )
                    : 0
        }
        let beginsBeforeGenerationCompletes = remainingRowCount > 0
        let canAvoidUnderrunOptimistically =
            isStartupEmissionBoundary && optimisticSurplusSeconds >= 0
        let requiredGenerationRowsPerSecond =
            maximumSustainableSecondsPerRow > 0 &&
                maximumSustainableSecondsPerRow.isFinite
                ? 1 / maximumSustainableSecondsPerRow
                : (maximumSustainableSecondsPerRow == .infinity ? 0 : .infinity)

        return TuringQwenNativeStreamingQueueEconomics(
            startupRowCount: startupRowCount,
            totalGeneratedRowCount: totalGeneratedRowCount,
            generatedRowsPerWindow: generatedRowsPerWindow,
            emittedCumulativeRowCounts: emittedCumulativeRowCounts,
            isStartupEmissionBoundary: isStartupEmissionBoundary,
            observedSecondsPerRow: observedSecondsPerRow,
            bufferedAudioSeconds: bufferedAudioSeconds,
            remainingGenerationSeconds: remainingGenerationSeconds,
            audioAppendedBeforeFinalRowSeconds:
                audioAppendedBeforeFinalRowSeconds,
            firstArrivalSurplusSeconds: firstArrivalSurplusSeconds,
            preFinalArrivalSurplusSeconds: preFinalArrivalSurplusSeconds,
            optimisticSurplusSeconds: optimisticSurplusSeconds,
            maximumSustainableSecondsPerRow:
                maximumSustainableSecondsPerRow,
            requiredGenerationRowsPerSecond:
                requiredGenerationRowsPerSecond,
            minimumPlaybackStartupRowCount:
                minimumPlaybackStartupRowCount,
            minimumStreamingStartupRowCount:
                minimumStreamingStartupRowCount,
            beginsBeforeGenerationCompletes:
                beginsBeforeGenerationCompletes,
            canAvoidUnderrunOptimistically:
                canAvoidUnderrunOptimistically,
            qualifiesForExperimentalPlaybackActivation:
                beginsBeforeGenerationCompletes &&
                canAvoidUnderrunOptimistically
        )
    }

    private static func survivesOptimistically(
        startupRowCount: Int,
        totalGeneratedRowCount: Int,
        observedSecondsPerRow: Double,
        generatedRowsPerWindow: Int
    ) -> Bool {
        let emissionRows = emissionRowCounts(
            totalGeneratedRowCount: totalGeneratedRowCount,
            generatedRowsPerWindow: generatedRowsPerWindow
        )
        guard emissionRows.contains(startupRowCount) else { return false }
        return arrivalSurpluses(
            startupRowCount: startupRowCount,
            emittedCumulativeRowCounts: emissionRows,
            observedSecondsPerRow: observedSecondsPerRow
        ).allSatisfy { $0 >= 0 }
    }

    private static func emissionRowCounts(
        totalGeneratedRowCount: Int,
        generatedRowsPerWindow: Int
    ) -> [Int] {
        var counts = Array(
            stride(
                from: generatedRowsPerWindow,
                through: totalGeneratedRowCount,
                by: generatedRowsPerWindow
            )
        )
        if counts.last != totalGeneratedRowCount {
            counts.append(totalGeneratedRowCount)
        }
        return counts
    }

    private static func arrivalSurpluses(
        startupRowCount: Int,
        emittedCumulativeRowCounts: [Int],
        observedSecondsPerRow: Double
    ) -> [Double] {
        var priorEmissionRowCount = startupRowCount
        var result: [Double] = []
        for emissionRowCount in emittedCumulativeRowCounts
            where emissionRowCount > startupRowCount {
            let audioAvailableBeforeArrival =
                Double(priorEmissionRowCount) *
                generatedAudioSecondsPerRow
            let generationSinceStartup =
                Double(emissionRowCount - startupRowCount) *
                observedSecondsPerRow
            result.append(
                audioAvailableBeforeArrival - generationSinceStartup
            )
            priorEmissionRowCount = emissionRowCount
        }
        return result
    }

    private static func maximumSustainableCadence(
        startupRowCount: Int,
        emittedCumulativeRowCounts: [Int]
    ) -> Double {
        var priorEmissionRowCount = startupRowCount
        var limits: [Double] = []
        for emissionRowCount in emittedCumulativeRowCounts
            where emissionRowCount > startupRowCount {
            let elapsedGeneratedRows = emissionRowCount - startupRowCount
            limits.append(
                Double(priorEmissionRowCount) *
                    generatedAudioSecondsPerRow /
                    Double(elapsedGeneratedRows)
            )
            priorEmissionRowCount = emissionRowCount
        }
        return limits.min() ?? .infinity
    }

    @discardableResult
    public static func requirePlaybackActivationViability(
        startupRowCount: Int,
        totalGeneratedRowCount: Int,
        observedSecondsPerRow: Double,
        generatedRowsPerWindow: Int =
            TuringQwenNativeExperimentalStreamingConfiguration
                .generatedRowsPerWindow
    ) throws -> TuringQwenNativeStreamingQueueEconomics {
        let result = try assess(
            startupRowCount: startupRowCount,
            totalGeneratedRowCount: totalGeneratedRowCount,
            observedSecondsPerRow: observedSecondsPerRow,
            generatedRowsPerWindow: generatedRowsPerWindow
        )
        guard result.qualifiesForExperimentalPlaybackActivation else {
            throw TuringQwenNativeError.invalidConfig(
                "Experimental PCM streaming cannot be activated: playback must begin before generation completes and the startup buffer must survive the observed cadence even under optimistic queue economics."
            )
        }
        return result
    }
}

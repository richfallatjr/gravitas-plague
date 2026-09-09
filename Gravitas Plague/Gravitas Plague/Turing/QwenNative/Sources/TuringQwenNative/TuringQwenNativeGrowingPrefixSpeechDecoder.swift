import Foundation

public struct TuringQwenNativeIncrementalPCMChunk: Sendable, Equatable {
    public let identity: TuringQwenNativeIncrementalCodebookStreamIdentity
    public let chunkIndex: Int
    public let generatedRowRange: Range<Int>
    public let generatedSampleRange: Range<Int>
    public let samples: [Float]
    public let sampleRate: Int

    public init(
        identity: TuringQwenNativeIncrementalCodebookStreamIdentity,
        chunkIndex: Int,
        generatedRowRange: Range<Int>,
        generatedSampleRange: Range<Int>,
        samples: [Float],
        sampleRate: Int
    ) {
        self.identity = identity
        self.chunkIndex = chunkIndex
        self.generatedRowRange = generatedRowRange
        self.generatedSampleRange = generatedSampleRange
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public enum TuringQwenNativeIncrementalPCMEvent: Sendable, Equatable {
    case chunk(TuringQwenNativeIncrementalPCMChunk)
    case finished(
        identity: TuringQwenNativeIncrementalCodebookStreamIdentity,
        generatedRowCount: Int,
        generatedSampleCount: Int,
        reachedEOS: Bool
    )
    case failed(
        identity: TuringQwenNativeIncrementalCodebookStreamIdentity,
        message: String
    )
}

/// Qualification-only Stage 4 decoder.
///
/// Each window recomputes the complete reference-plus-generated prefix and
/// publishes only the newly committed 1,920-sample-per-row suffix. This keeps
/// the current causal decoder math intact and gives a parity oracle, but its
/// repeated work is intentionally not presented as the final efficient
/// rolling-state decoder.
///
/// This actor also does not own GPU admission or recovery containment. It must
/// remain inactive until a qualification driver places every decode under the
/// same admission/recovery contract as the canonical speech decode coordinator.
public actor TuringQwenNativeGrowingPrefixSpeechDecoder {
    private struct StreamState {
        let identity: TuringQwenNativeIncrementalCodebookStreamIdentity
        let referenceRows: [[Int]]
        let generatedPrefixRows: [[Int]]
        let codebookCount: Int
        let performanceMode: TuringQwenNativePerformanceMode
        var emittedGeneratedSampleCount: Int
        var nextChunkIndex: Int

        var emittedGeneratedRowCount: Int {
            generatedPrefixRows.count
        }
    }

    private let session: TuringQwenNativeSpeechDecoderSession
    private var states: [UUID: StreamState] = [:]
    private var terminalStreamIDs = Set<UUID>()
    private var nextDecodeID = 0

    public init(
        modelRoot: URL,
        configuration: TuringQwenNativeExperimentalStreamingConfiguration
    ) throws {
        guard configuration.mode == .qualificationGrowingPrefix else {
            throw TuringQwenNativeError.invalidConfig(
                "Growing-prefix speech decode is qualification-only and requires explicit experimental activation."
            )
        }
        session = try TuringQwenNativeSpeechDecoderSession(modelRoot: modelRoot)
        guard session.config.decodeUpsampleRate ==
                TuringQwenNativeExperimentalStreamingConfiguration
                    .samplesPerGeneratedRow,
              session.config.outputSampleRate ==
                TuringQwenNativeExperimentalStreamingConfiguration
                    .outputSampleRate else {
            throw TuringQwenNativeError.invalidConfig(
                "Experimental streaming constants do not match the installed speech decoder configuration."
            )
        }
    }

    public func consume(
        _ event: TuringQwenNativeIncrementalCodebookEvent
    ) throws -> TuringQwenNativeIncrementalPCMEvent {
        switch event {
        case .window(let window):
            return .chunk(try decode(window))

        case .finished(let terminal):
            guard terminalStreamIDs.contains(terminal.identity.streamID) == false,
                  let state = states[terminal.identity.streamID],
                  state.identity == terminal.identity,
                  state.emittedGeneratedRowCount == terminal.generatedRowCount else {
                throw TuringQwenNativeError.invalidConfig(
                    "Incremental codebook terminal is duplicate, missing, or out of order."
                )
            }
            states.removeValue(forKey: terminal.identity.streamID)
            terminalStreamIDs.insert(terminal.identity.streamID)
            return .finished(
                identity: terminal.identity,
                generatedRowCount: terminal.generatedRowCount,
                generatedSampleCount: state.emittedGeneratedSampleCount,
                reachedEOS: terminal.reachedEOS
            )

        case .failed(let identity, let message):
            guard terminalStreamIDs.contains(identity.streamID) == false,
                  states[identity.streamID]?.identity == identity ||
                    states[identity.streamID] == nil else {
                throw TuringQwenNativeError.invalidConfig(
                    "Incremental codebook failure terminal is duplicate or changes stream ownership."
                )
            }
            states.removeValue(forKey: identity.streamID)
            terminalStreamIDs.insert(identity.streamID)
            return .failed(identity: identity, message: message)
        }
    }

    private func decode(
        _ window: TuringQwenNativeIncrementalCodebookWindow
    ) throws -> TuringQwenNativeIncrementalPCMChunk {
        guard terminalStreamIDs.contains(window.identity.streamID) == false else {
            throw TuringQwenNativeError.invalidConfig(
                "Incremental codebook window arrived after a terminal event."
            )
        }

        let prior = states[window.identity.streamID]
        if let prior {
            guard prior.identity == window.identity,
                  prior.referenceRows == window.referenceRows,
                  prior.codebookCount == window.codebookCount,
                  prior.performanceMode == window.performanceMode else {
                throw TuringQwenNativeError.invalidConfig(
                    "Incremental codebook stream metadata changed within a stream."
                )
            }
        }
        let plan = try TuringQwenNativeGrowingPrefixDecodePlan.make(
            window: window,
            previouslyEmittedGeneratedPrefixRows:
                prior?.generatedPrefixRows ?? []
        )

        try Task.checkCancellation()
        let decodeID = nextDecodeID
        nextDecodeID += 1
        let fullAudio = try session.decode(
            rows: plan.rowsForDecode,
            performanceMode: window.performanceMode,
            diagnosticContext: TuringQwenNativeSpeechDecoderDiagnosticContext(
                runID: window.identity.runID,
                instanceID: window.identity.instanceID.rawValue,
                segmentIndex: window.identity.segmentIndex,
                decodeID: decodeID,
                residencyOwnerID: nil,
                weightStoreID: nil,
                laneMutableStateID: nil
            )
        )
        try Task.checkCancellation()
        guard fullAudio.sampleRate ==
                TuringQwenNativeExperimentalStreamingConfiguration.outputSampleRate,
              plan.fullDecodeSampleRange.upperBound <= fullAudio.samples.count else {
            throw TuringQwenNativeError.invalidConfig(
                "Growing-prefix decode did not materialize the planned PCM suffix."
            )
        }

        let samples = Array(fullAudio.samples[plan.fullDecodeSampleRange])
        let expectedSampleCount =
            window.newGeneratedRowRange.count *
            TuringQwenNativeExperimentalStreamingConfiguration
                .samplesPerGeneratedRow
        guard samples.count == expectedSampleCount else {
            throw TuringQwenNativeError.invalidConfig(
                "Growing-prefix PCM suffix is not row aligned."
            )
        }

        let chunkIndex = prior?.nextChunkIndex ?? 0
        states[window.identity.streamID] = StreamState(
            identity: window.identity,
            referenceRows: window.referenceRows,
            generatedPrefixRows: window.generatedPrefixRows,
            codebookCount: window.codebookCount,
            performanceMode: window.performanceMode,
            emittedGeneratedSampleCount:
                plan.generatedOutputSampleRange.upperBound,
            nextChunkIndex: chunkIndex + 1
        )
        return TuringQwenNativeIncrementalPCMChunk(
            identity: window.identity,
            chunkIndex: chunkIndex,
            generatedRowRange: window.newGeneratedRowRange,
            generatedSampleRange: plan.generatedOutputSampleRange,
            samples: samples,
            sampleRate: fullAudio.sampleRate
        )
    }
}

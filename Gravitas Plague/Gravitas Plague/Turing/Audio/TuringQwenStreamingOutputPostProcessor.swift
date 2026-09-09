import AVFoundation
import Foundation

/// Stateful, inactive-until-wired output processing for Stage 4 PCM chunks.
///
/// Each append recomputes the deterministic transform over the cumulative input
/// and exposes only the prefix that cannot change when later PCM arrives. The
/// unresolved tail remains private until it becomes stable or `finish()` flushes
/// it with the one and only trailing fade. This intentionally favors exact
/// parity with the shipping batch transform over incremental compute efficiency.
nonisolated struct TuringQwenStreamingOutputPostProcessor: Sendable {
    struct InputChunk: Sendable, Equatable {
        let chunkIndex: Int
        /// Offset in interleaved Float samples, not per-channel frames.
        let interleavedSampleOffset: Int
        let samples: [Float]

        init(
            chunkIndex: Int,
            interleavedSampleOffset: Int,
            samples: [Float]
        ) {
            self.chunkIndex = chunkIndex
            self.interleavedSampleOffset = interleavedSampleOffset
            self.samples = samples
        }
    }

    struct OutputChunk: Sendable, Equatable {
        /// Dense output sequence independent of the source chunk sequence.
        let chunkIndex: Int
        /// Offset in the final interleaved processed stream.
        let interleavedSampleOffset: Int
        let samples: [Float]
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let isFinal: Bool
        let cumulativeInputSampleCount: Int
        let cumulativeOutputSampleCount: Int
    }

    struct Metrics: Sendable, Equatable {
        let inputChunkCount: Int
        let outputChunkCount: Int
        let inputSampleCount: Int
        let emittedOutputSampleCount: Int
        let heldOutputSampleCount: Int
        let expectedNextInputChunkIndex: Int
        let expectedNextInputSampleOffset: Int
        let isFinished: Bool
    }

    enum ProcessingError: Error, Equatable, LocalizedError {
        case invalidSampleRate(Double)
        case invalidChannelCount(AVAudioChannelCount)
        case invalidPlaybackRate(Double)
        case emptyInputChunk(index: Int)
        case partialInterleavedFrame(
            chunkIndex: Int,
            sampleCount: Int,
            channelCount: AVAudioChannelCount
        )
        case unexpectedInputChunkIndex(expected: Int, actual: Int)
        case unexpectedInputSampleOffset(expected: Int, actual: Int)
        case alreadyFinished
        case unstablePreviouslyEmittedSample(index: Int)

        var errorDescription: String? {
            switch self {
            case .invalidSampleRate(let value):
                return "Streaming Qwen output sample rate is invalid: \(value)."
            case .invalidChannelCount(let value):
                return "Streaming Qwen output channel count is invalid: \(value)."
            case .invalidPlaybackRate(let value):
                return "Streaming Qwen output playback rate is invalid: \(value)."
            case .emptyInputChunk(let index):
                return "Streaming Qwen input chunk \(index) is empty."
            case .partialInterleavedFrame(
                let chunkIndex,
                let sampleCount,
                let channelCount
            ):
                return "Streaming Qwen input chunk \(chunkIndex) has \(sampleCount) samples, which is not divisible by \(channelCount) channels."
            case .unexpectedInputChunkIndex(let expected, let actual):
                return "Streaming Qwen input chunk index \(actual) arrived; expected \(expected)."
            case .unexpectedInputSampleOffset(let expected, let actual):
                return "Streaming Qwen input sample offset \(actual) arrived; expected \(expected)."
            case .alreadyFinished:
                return "Streaming Qwen output processing is already finished."
            case .unstablePreviouslyEmittedSample(let index):
                return "Streaming Qwen output sample \(index) changed after it was emitted."
            }
        }
    }

    let voiceID: String
    let playbackRate: Double
    let sampleRate: Double
    let channelCount: AVAudioChannelCount

    private let heldTailFrameCount: Int
    private var inputSamples: [Float] = []
    private var emittedOutputSamples: [Float] = []
    private var nextInputChunkIndex = 0
    private var nextOutputChunkIndex = 0
    private var lastRenderedOutputSampleCount = 0
    private var finished = false

    init(
        policy: TuringQwenOutputProcessingPolicy,
        sampleRate: Double,
        channelCount: AVAudioChannelCount,
        heldTailFrameCount: Int =
            TuringQwenDeterministicTimeStretcher.maximumEdgeFadeFrameCount
    ) throws {
        guard sampleRate.isFinite,
              sampleRate > 0 else {
            throw ProcessingError.invalidSampleRate(sampleRate)
        }
        guard channelCount > 0 else {
            throw ProcessingError.invalidChannelCount(channelCount)
        }
        guard policy.playbackRate.isFinite,
              policy.playbackRate > 0.25,
              policy.playbackRate <= 2 else {
            throw ProcessingError.invalidPlaybackRate(policy.playbackRate)
        }

        voiceID = policy.voiceID
        playbackRate = policy.playbackRate
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.heldTailFrameCount = max(
            heldTailFrameCount,
            TuringQwenDeterministicTimeStretcher
                .maximumEdgeFadeFrameCount
        )
    }

    var metrics: Metrics {
        Metrics(
            inputChunkCount: nextInputChunkIndex,
            outputChunkCount: nextOutputChunkIndex,
            inputSampleCount: inputSamples.count,
            emittedOutputSampleCount: emittedOutputSamples.count,
            heldOutputSampleCount: max(
                0,
                lastRenderedOutputSampleCount - emittedOutputSamples.count
            ),
            expectedNextInputChunkIndex: nextInputChunkIndex,
            expectedNextInputSampleOffset: inputSamples.count,
            isFinished: finished
        )
    }

    /// Appends one ordered source chunk. A nil result means the cumulative
    /// transform has not yet produced enough immutable output to publish.
    mutating func append(
        _ chunk: InputChunk
    ) throws -> OutputChunk? {
        guard finished == false else {
            throw ProcessingError.alreadyFinished
        }
        guard chunk.chunkIndex == nextInputChunkIndex else {
            throw ProcessingError.unexpectedInputChunkIndex(
                expected: nextInputChunkIndex,
                actual: chunk.chunkIndex
            )
        }
        guard chunk.interleavedSampleOffset == inputSamples.count else {
            throw ProcessingError.unexpectedInputSampleOffset(
                expected: inputSamples.count,
                actual: chunk.interleavedSampleOffset
            )
        }
        guard chunk.samples.isEmpty == false else {
            throw ProcessingError.emptyInputChunk(index: chunk.chunkIndex)
        }
        let channels = Int(channelCount)
        guard chunk.samples.count.isMultiple(of: channels) else {
            throw ProcessingError.partialInterleavedFrame(
                chunkIndex: chunk.chunkIndex,
                sampleCount: chunk.samples.count,
                channelCount: channelCount
            )
        }

        var cumulativeInput = inputSamples
        cumulativeInput.append(contentsOf: chunk.samples)

        let rendered: TuringQwenDeterministicTimeStretcher.RenderResult
        let targetSampleCount: Int
        if shouldStretch {
            rendered = TuringQwenDeterministicTimeStretcher.render(
                samples: cumulativeInput,
                channelCount: channels,
                rate: playbackRate,
                edgeFadePolicy: .leading
            )
            try validateEmittedPrefix(of: rendered.samples)

            // Once the render is this long, its leading fade has reached the
            // same fixed 240-frame length the final batch render will use.
            let leadingFadeIsStable = rendered.frameCount >=
                TuringQwenDeterministicTimeStretcher
                    .maximumEdgeFadeFrameCount * 8
            let stableFrames = leadingFadeIsStable
                ? max(0, rendered.stableFrameCount - heldTailFrameCount)
                : 0
            targetSampleCount = min(
                rendered.samples.count,
                stableFrames * channels
            )
        } else {
            rendered = TuringQwenDeterministicTimeStretcher.RenderResult(
                samples: cumulativeInput,
                stableFrameCount: cumulativeInput.count / channels,
                frameCount: cumulativeInput.count / channels
            )
            try validateEmittedPrefix(of: rendered.samples)
            targetSampleCount = rendered.samples.count
        }

        // Commit input accounting only after every invariant has passed.
        inputSamples = cumulativeInput
        nextInputChunkIndex += 1
        lastRenderedOutputSampleCount = rendered.samples.count
        return makeOutputChunk(
            renderedSamples: rendered.samples,
            targetSampleCount: targetSampleCount,
            isFinal: false
        )
    }

    /// Finalizes the stream and emits every held sample with the sole trailing
    /// fade. The final marker is returned even when it carries zero samples.
    mutating func finish() throws -> OutputChunk {
        guard finished == false else {
            throw ProcessingError.alreadyFinished
        }

        let renderedSamples: [Float]
        if shouldStretch {
            renderedSamples = TuringQwenDeterministicTimeStretcher.stretch(
                samples: inputSamples,
                channelCount: Int(channelCount),
                rate: playbackRate,
                edgeFadePolicy: .leadingAndTrailing
            )
        } else {
            renderedSamples = inputSamples
        }
        try validateEmittedPrefix(of: renderedSamples)

        lastRenderedOutputSampleCount = renderedSamples.count
        finished = true
        return makeOutputChunk(
            renderedSamples: renderedSamples,
            targetSampleCount: renderedSamples.count,
            isFinal: true
        )!
    }

    private var shouldStretch: Bool {
        abs(playbackRate - 1) > 0.001
    }

    private func validateEmittedPrefix(
        of renderedSamples: [Float]
    ) throws {
        guard renderedSamples.count >= emittedOutputSamples.count else {
            throw ProcessingError.unstablePreviouslyEmittedSample(
                index: renderedSamples.count
            )
        }
        for index in emittedOutputSamples.indices {
            guard renderedSamples[index].bitPattern ==
                    emittedOutputSamples[index].bitPattern else {
                throw ProcessingError.unstablePreviouslyEmittedSample(
                    index: index
                )
            }
        }
    }

    private mutating func makeOutputChunk(
        renderedSamples: [Float],
        targetSampleCount: Int,
        isFinal: Bool
    ) -> OutputChunk? {
        let outputOffset = emittedOutputSamples.count
        let clampedTarget = min(
            renderedSamples.count,
            max(outputOffset, targetSampleCount)
        )
        guard clampedTarget > outputOffset || isFinal else {
            return nil
        }

        let samples = Array(
            renderedSamples[outputOffset..<clampedTarget]
        )
        emittedOutputSamples.append(contentsOf: samples)
        let output = OutputChunk(
            chunkIndex: nextOutputChunkIndex,
            interleavedSampleOffset: outputOffset,
            samples: samples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            isFinal: isFinal,
            cumulativeInputSampleCount: inputSamples.count,
            cumulativeOutputSampleCount: emittedOutputSamples.count
        )
        nextOutputChunkIndex += 1
        return output
    }
}

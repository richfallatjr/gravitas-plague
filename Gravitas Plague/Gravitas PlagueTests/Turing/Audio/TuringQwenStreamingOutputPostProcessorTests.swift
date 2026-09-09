import AVFoundation
import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringQwenStreamingOutputPostProcessorTests: XCTestCase {
    func testRefactoredBatchStretcherIsBitExactWithLegacyAlgorithm() {
        let mono = makeSignal(frameCount: 18_000, channelCount: 1)
        let stereo = makeSignal(frameCount: 12_000, channelCount: 2)

        assertBitExact(
            TuringQwenDeterministicTimeStretcher.stretch(
                samples: mono,
                channelCount: 1,
                rate: 0.85
            ),
            LegacyReferenceStretcher.stretch(
                samples: mono,
                channelCount: 1,
                rate: 0.85
            )
        )
        assertBitExact(
            TuringQwenDeterministicTimeStretcher.stretch(
                samples: stereo,
                channelCount: 2,
                rate: 0.85
            ),
            LegacyReferenceStretcher.stretch(
                samples: stereo,
                channelCount: 2,
                rate: 0.85
            )
        )
    }

    func testChunkedPointEightFiveOutputIsBitExactWithOneShotOutput() throws {
        let input = makeSignal(frameCount: 36_000, channelCount: 1)
        let expected = LegacyReferenceStretcher.stretch(
            samples: input,
            channelCount: 1,
            rate: 0.85
        )
        var processor = try TuringQwenStreamingOutputPostProcessor(
            policy: TuringQwenOutputProcessingPolicy(
                voiceID: "test.big-mike",
                playbackRate: 0.85
            ),
            sampleRate: 24_000,
            channelCount: 1
        )

        var assembled: [Float] = []
        var outputChunks: [TuringQwenStreamingOutputPostProcessor.OutputChunk] = []
        var inputOffset = 0
        let chunkFrameCounts = [6_400, 4_800, 8_000, 5_600, 7_200, 4_000]
        for (chunkIndex, frameCount) in chunkFrameCounts.enumerated() {
            let end = inputOffset + frameCount
            let output = try processor.append(
                .init(
                    chunkIndex: chunkIndex,
                    interleavedSampleOffset: inputOffset,
                    samples: Array(input[inputOffset..<end])
                )
            )
            inputOffset = end
            if let output {
                XCTAssertEqual(output.chunkIndex, outputChunks.count)
                XCTAssertEqual(
                    output.interleavedSampleOffset,
                    assembled.count
                )
                XCTAssertFalse(output.isFinal)
                assembled.append(contentsOf: output.samples)
                outputChunks.append(output)
            }
        }

        XCTAssertEqual(inputOffset, input.count)
        XCTAssertFalse(outputChunks.isEmpty)
        XCTAssertGreaterThan(processor.metrics.heldOutputSampleCount, 0)
        XCTAssertLessThan(assembled.count, expected.count)

        let final = try processor.finish()
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(final.chunkIndex, outputChunks.count)
        XCTAssertEqual(final.interleavedSampleOffset, assembled.count)
        XCTAssertFalse(final.samples.isEmpty)
        assembled.append(contentsOf: final.samples)

        assertBitExact(assembled, expected)
        XCTAssertEqual(processor.metrics.inputChunkCount, chunkFrameCounts.count)
        XCTAssertEqual(
            processor.metrics.outputChunkCount,
            outputChunks.count + 1
        )
        XCTAssertEqual(processor.metrics.inputSampleCount, input.count)
        XCTAssertEqual(
            processor.metrics.emittedOutputSampleCount,
            expected.count
        )
        XCTAssertEqual(processor.metrics.heldOutputSampleCount, 0)
        XCTAssertTrue(processor.metrics.isFinished)
    }

    func testStereoChunksPreserveInterleavingAndSampleAccounting() throws {
        let channelCount = 2
        let input = makeSignal(
            frameCount: 24_000,
            channelCount: channelCount
        )
        let expected = LegacyReferenceStretcher.stretch(
            samples: input,
            channelCount: channelCount,
            rate: 0.85
        )
        var processor = try TuringQwenStreamingOutputPostProcessor(
            policy: TuringQwenOutputProcessingPolicy(
                voiceID: "test.stereo",
                playbackRate: 0.85
            ),
            sampleRate: 24_000,
            channelCount: AVAudioChannelCount(channelCount)
        )

        var assembled: [Float] = []
        var inputSampleOffset = 0
        let chunkFrameCounts = [5_000, 7_000, 4_000, 8_000]
        for (chunkIndex, frameCount) in chunkFrameCounts.enumerated() {
            let sampleCount = frameCount * channelCount
            let end = inputSampleOffset + sampleCount
            if let output = try processor.append(
                .init(
                    chunkIndex: chunkIndex,
                    interleavedSampleOffset: inputSampleOffset,
                    samples: Array(input[inputSampleOffset..<end])
                )
            ) {
                XCTAssertEqual(output.interleavedSampleOffset, assembled.count)
                XCTAssertEqual(output.samples.count % channelCount, 0)
                XCTAssertEqual(output.channelCount, 2)
                assembled.append(contentsOf: output.samples)
            }
            inputSampleOffset = end
        }
        let final = try processor.finish()
        XCTAssertEqual(final.interleavedSampleOffset, assembled.count)
        XCTAssertEqual(final.samples.count % channelCount, 0)
        assembled.append(contentsOf: final.samples)

        assertBitExact(assembled, expected)
        XCTAssertEqual(processor.metrics.inputSampleCount, input.count)
        XCTAssertEqual(
            processor.metrics.expectedNextInputSampleOffset,
            input.count
        )
    }

    func testOutOfOrderInputIsRejectedWithoutAdvancingState() throws {
        let first = makeSignal(frameCount: 6_400, channelCount: 1)
        let second = makeSignal(frameCount: 4_800, channelCount: 1)
        var processor = try TuringQwenStreamingOutputPostProcessor(
            policy: .bigMike,
            sampleRate: 24_000,
            channelCount: 1
        )

        _ = try processor.append(
            .init(
                chunkIndex: 0,
                interleavedSampleOffset: 0,
                samples: first
            )
        )
        let before = processor.metrics

        do {
            _ = try processor.append(
                .init(
                    chunkIndex: 2,
                    interleavedSampleOffset: first.count,
                    samples: second
                )
            )
            XCTFail("Expected out-of-order chunk rejection.")
        } catch {
            XCTAssertEqual(
                error as? TuringQwenStreamingOutputPostProcessor.ProcessingError,
                .unexpectedInputChunkIndex(expected: 1, actual: 2)
            )
        }
        XCTAssertEqual(processor.metrics, before)

        do {
            _ = try processor.append(
                .init(
                    chunkIndex: 1,
                    interleavedSampleOffset: first.count + 1,
                    samples: second
                )
            )
            XCTFail("Expected noncontiguous sample offset rejection.")
        } catch {
            XCTAssertEqual(
                error as? TuringQwenStreamingOutputPostProcessor.ProcessingError,
                .unexpectedInputSampleOffset(
                    expected: first.count,
                    actual: first.count + 1
                )
            )
        }
        XCTAssertEqual(processor.metrics, before)

        _ = try processor.append(
            .init(
                chunkIndex: 1,
                interleavedSampleOffset: first.count,
                samples: second
            )
        )
        XCTAssertEqual(processor.metrics.inputChunkCount, 2)
        XCTAssertEqual(
            processor.metrics.inputSampleCount,
            first.count + second.count
        )
    }

    func testRateOneBypassEmitsImmediatelyAndFinishReturnsFinalMarker() throws {
        let first: [Float] = [0.1, -0.2, 0.3, -0.4]
        let second: [Float] = [0.5, -0.6]
        var processor = try TuringQwenStreamingOutputPostProcessor(
            policy: TuringQwenOutputProcessingPolicy(
                voiceID: "test.unstretched",
                playbackRate: 1
            ),
            sampleRate: 24_000,
            channelCount: 1
        )

        let output0 = try XCTUnwrap(
            processor.append(
                .init(
                    chunkIndex: 0,
                    interleavedSampleOffset: 0,
                    samples: first
                )
            )
        )
        let output1 = try XCTUnwrap(
            processor.append(
                .init(
                    chunkIndex: 1,
                    interleavedSampleOffset: first.count,
                    samples: second
                )
            )
        )
        let final = try processor.finish()

        XCTAssertEqual(output0.samples, first)
        XCTAssertEqual(output0.interleavedSampleOffset, 0)
        XCTAssertEqual(output1.samples, second)
        XCTAssertEqual(output1.interleavedSampleOffset, first.count)
        XCTAssertTrue(final.isFinal)
        XCTAssertTrue(final.samples.isEmpty)
        XCTAssertEqual(
            final.interleavedSampleOffset,
            first.count + second.count
        )
        XCTAssertThrowsError(try processor.finish())
        XCTAssertThrowsError(
            try processor.append(
                .init(
                    chunkIndex: 2,
                    interleavedSampleOffset: first.count + second.count,
                    samples: [0.7]
                )
            )
        )
    }

    private func makeSignal(
        frameCount: Int,
        channelCount: Int
    ) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(frameCount * channelCount)
        for frame in 0..<frameCount {
            let seconds = Double(frame) / 24_000
            for channel in 0..<channelCount {
                let phase = Double(channel) * 0.37
                let carrier = 0.31 * sin(
                    2 * .pi * 173 * seconds + phase
                )
                let harmonic = 0.17 * sin(
                    2 * .pi * 337 * seconds + phase * 0.5
                )
                let pulse = frame.isMultiple(of: 1_103) ? 0.09 : 0
                samples.append(Float(carrier + harmonic + pulse))
            }
        }
        return samples
    }

    private func assertBitExact(
        _ actual: [Float],
        _ expected: [Float],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        guard actual.count == expected.count else {
            return
        }
        for index in actual.indices {
            XCTAssertEqual(
                actual[index].bitPattern,
                expected[index].bitPattern,
                "Float changed at sample \(index)",
                file: file,
                line: line
            )
        }
    }
}

/// Frozen copy of the previously shipping batch implementation. It makes the
/// refactor test independent from the new shared primitive.
private enum LegacyReferenceStretcher {
    static func stretch(
        samples: [Float],
        channelCount: Int,
        rate: Double
    ) -> [Float] {
        guard samples.isEmpty == false,
              channelCount > 0,
              rate > 0 else {
            return samples
        }

        if channelCount == 1 {
            return stretchMono(samples, rate: rate)
        }

        let frameCount = samples.count / channelCount
        guard frameCount > 0 else {
            return samples
        }

        var stretchedChannels: [[Float]] = []
        stretchedChannels.reserveCapacity(channelCount)
        for channelIndex in 0..<channelCount {
            var mono: [Float] = []
            mono.reserveCapacity(frameCount)
            for frameIndex in 0..<frameCount {
                mono.append(samples[frameIndex * channelCount + channelIndex])
            }
            stretchedChannels.append(stretchMono(mono, rate: rate))
        }

        let stretchedFrameCount = stretchedChannels.map(\.count).min() ?? 0
        guard stretchedFrameCount > 0 else {
            return samples
        }

        var interleaved: [Float] = []
        interleaved.reserveCapacity(stretchedFrameCount * channelCount)
        for frameIndex in 0..<stretchedFrameCount {
            for channelIndex in 0..<channelCount {
                interleaved.append(stretchedChannels[channelIndex][frameIndex])
            }
        }
        return interleaved
    }

    private static func stretchMono(
        _ input: [Float],
        rate: Double
    ) -> [Float] {
        guard input.count > 32 else {
            return input
        }

        let frameSize = 1_024
        let synthesisHop = 512
        let analysisHop = max(
            1,
            Int((Double(synthesisHop) * rate).rounded())
        )
        let searchRadius = max(
            32,
            min(frameSize / 4, analysisHop / 2)
        )
        let targetFrameCount = max(
            input.count,
            Int(ceil(Double(input.count) / rate))
        )
        let estimatedFrameCount = targetFrameCount + frameSize * 4
        var accumulator = Array(
            repeating: Float(0),
            count: estimatedFrameCount
        )
        var weights = Array(
            repeating: Float(0),
            count: estimatedFrameCount
        )
        let window = hannWindow(length: frameSize)

        var frameIndex = 0
        var furthestWritten = 0

        while frameIndex * analysisHop < input.count {
            let nominalInputPosition = frameIndex * analysisHop
            let outputPosition = frameIndex * synthesisHop
            ensureCapacity(
                outputPosition + frameSize,
                accumulator: &accumulator,
                weights: &weights
            )

            let inputPosition = bestInputPosition(
                input: input,
                output: accumulator,
                weights: weights,
                nominalInputPosition: nominalInputPosition,
                outputPosition: outputPosition,
                frameSize: frameSize,
                searchRadius: searchRadius
            )

            for frameOffset in 0..<frameSize {
                let sample = sample(
                    input,
                    at: inputPosition + frameOffset
                )
                let weight = window[frameOffset]
                let outputIndex = outputPosition + frameOffset
                accumulator[outputIndex] += sample * weight
                weights[outputIndex] += weight
            }

            furthestWritten = max(
                furthestWritten,
                outputPosition + frameSize
            )
            frameIndex += 1
        }

        let normalizedCount = min(
            max(targetFrameCount, 1),
            max(furthestWritten, 1)
        )
        var output = Array(repeating: Float(0), count: normalizedCount)
        for index in 0..<normalizedCount {
            if weights[index] > 0.000_001 {
                output[index] = clamp(accumulator[index] / weights[index])
            }
        }

        applyShortFadeInOut(samples: &output)
        return output
    }

    private static func bestInputPosition(
        input: [Float],
        output: [Float],
        weights: [Float],
        nominalInputPosition: Int,
        outputPosition: Int,
        frameSize: Int,
        searchRadius: Int
    ) -> Int {
        guard outputPosition > 0 else {
            return nominalInputPosition
        }

        let searchStart = max(0, nominalInputPosition - searchRadius)
        let searchEnd = min(
            max(0, input.count - 1),
            nominalInputPosition + searchRadius
        )
        let compareLength = min(
            frameSize / 2,
            max(64, frameSize - 256)
        )
        let comparisonStride = 8

        var bestPosition = nominalInputPosition
        var bestScore = -Double.greatestFiniteMagnitude

        for candidate in stride(
            from: searchStart,
            through: searchEnd,
            by: comparisonStride
        ) {
            var cross = Double(0)
            var outputEnergy = Double(0)
            var inputEnergy = Double(0)

            for offset in stride(
                from: 0,
                to: compareLength,
                by: comparisonStride
            ) {
                let outputIndex = outputPosition + offset
                guard outputIndex < output.count,
                      weights[outputIndex] > 0.000_001 else {
                    continue
                }

                let outputSample = Double(
                    output[outputIndex] / weights[outputIndex]
                )
                let inputSample = Double(
                    sample(input, at: candidate + offset)
                )
                cross += outputSample * inputSample
                outputEnergy += outputSample * outputSample
                inputEnergy += inputSample * inputSample
            }

            guard outputEnergy > 0,
                  inputEnergy > 0 else {
                continue
            }

            let score = cross / sqrt(outputEnergy * inputEnergy)
            if score > bestScore {
                bestScore = score
                bestPosition = candidate
            }
        }

        return bestPosition
    }

    private static func hannWindow(length: Int) -> [Float] {
        guard length > 1 else {
            return [1]
        }
        return (0..<length).map { index in
            Float(
                0.5 - 0.5 * cos(
                    (2 * Double.pi * Double(index)) /
                        Double(length - 1)
                )
            )
        }
    }

    private static func sample(_ input: [Float], at index: Int) -> Float {
        guard index >= 0,
              index < input.count else {
            return 0
        }
        let value = input[index]
        return value.isFinite ? value : 0
    }

    private static func ensureCapacity(
        _ requiredCount: Int,
        accumulator: inout [Float],
        weights: inout [Float]
    ) {
        guard requiredCount > accumulator.count else {
            return
        }
        let additionalCount = requiredCount - accumulator.count
        accumulator.append(
            contentsOf: repeatElement(0, count: additionalCount)
        )
        weights.append(
            contentsOf: repeatElement(0, count: additionalCount)
        )
    }

    private static func applyShortFadeInOut(samples: inout [Float]) {
        let fadeLength = min(240, samples.count / 8)
        guard fadeLength > 1 else {
            return
        }

        for index in 0..<fadeLength {
            let gain = Float(index) / Float(fadeLength)
            samples[index] *= gain
            let tailIndex = samples.count - index - 1
            samples[tailIndex] *= gain
        }
    }

    private static func clamp(_ value: Float) -> Float {
        guard value.isFinite else {
            return 0
        }
        return min(1, max(-1, value))
    }
}

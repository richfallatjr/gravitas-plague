import Foundation

/// Deterministic WSOLA-style processing shared by batch and prospective
/// streaming Qwen playback. The streaming caller may emit only
/// `stableFrameCount`; samples after that boundary can still change when more
/// input arrives.
nonisolated enum TuringQwenDeterministicTimeStretcher {
    enum EdgeFadePolicy: Sendable, Equatable {
        case none
        case leading
        case leadingAndTrailing
    }

    struct RenderResult: Sendable {
        let samples: [Float]
        /// Per-channel output frames that cannot be changed by appending input.
        let stableFrameCount: Int

        let frameCount: Int
    }

    static let frameSize = 1_024
    static let synthesisHop = 512
    static let maximumEdgeFadeFrameCount = 240

    static func stretch(
        samples: [Float],
        channelCount: Int,
        rate: Double,
        edgeFadePolicy: EdgeFadePolicy = .leadingAndTrailing
    ) -> [Float] {
        render(
            samples: samples,
            channelCount: channelCount,
            rate: rate,
            edgeFadePolicy: edgeFadePolicy
        ).samples
    }

    static func render(
        samples: [Float],
        channelCount: Int,
        rate: Double,
        edgeFadePolicy: EdgeFadePolicy
    ) -> RenderResult {
        guard samples.isEmpty == false,
              channelCount > 0,
              rate > 0 else {
            return RenderResult(
                samples: samples,
                stableFrameCount: 0,
                frameCount: channelCount > 0 ? samples.count / channelCount : 0
            )
        }

        if channelCount == 1 {
            let mono = renderMono(
                samples,
                rate: rate,
                edgeFadePolicy: edgeFadePolicy
            )
            return RenderResult(
                samples: mono.samples,
                stableFrameCount: mono.stableFrameCount,
                frameCount: mono.samples.count
            )
        }

        let inputFrameCount = samples.count / channelCount
        guard inputFrameCount > 0 else {
            return RenderResult(
                samples: samples,
                stableFrameCount: 0,
                frameCount: 0
            )
        }

        var renderedChannels: [MonoRenderResult] = []
        renderedChannels.reserveCapacity(channelCount)
        for channelIndex in 0..<channelCount {
            var mono: [Float] = []
            mono.reserveCapacity(inputFrameCount)
            for frameIndex in 0..<inputFrameCount {
                mono.append(samples[frameIndex * channelCount + channelIndex])
            }
            renderedChannels.append(
                renderMono(
                    mono,
                    rate: rate,
                    edgeFadePolicy: edgeFadePolicy
                )
            )
        }

        let outputFrameCount = renderedChannels.map(\.samples.count).min() ?? 0
        guard outputFrameCount > 0 else {
            return RenderResult(
                samples: samples,
                stableFrameCount: 0,
                frameCount: inputFrameCount
            )
        }

        var interleaved: [Float] = []
        interleaved.reserveCapacity(outputFrameCount * channelCount)
        for frameIndex in 0..<outputFrameCount {
            for channelIndex in 0..<channelCount {
                interleaved.append(renderedChannels[channelIndex].samples[frameIndex])
            }
        }

        return RenderResult(
            samples: interleaved,
            stableFrameCount: min(
                outputFrameCount,
                renderedChannels.map(\.stableFrameCount).min() ?? 0
            ),
            frameCount: outputFrameCount
        )
    }

    private struct MonoRenderResult {
        let samples: [Float]
        let stableFrameCount: Int
    }

    private static func renderMono(
        _ input: [Float],
        rate: Double,
        edgeFadePolicy: EdgeFadePolicy
    ) -> MonoRenderResult {
        guard input.count > 32 else {
            // Preserve the existing batch behavior for tiny buffers. A
            // streaming caller treats this result as unstable until finish.
            return MonoRenderResult(samples: input, stableFrameCount: 0)
        }

        let analysisHop = max(
            1,
            Int((Double(synthesisHop) * rate).rounded())
        )
        let searchRadius = max(
            32,
            min(frameSize / 4, analysisHop / 2)
        )
        let compareLength = min(
            frameSize / 2,
            max(64, frameSize - 256)
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
        var stableSynthesisFrameCount = 0

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
                searchRadius: searchRadius,
                compareLength: compareLength
            )

            for frameOffset in 0..<frameSize {
                let value = sample(
                    input,
                    at: inputPosition + frameOffset
                )
                let weight = window[frameOffset]
                let outputIndex = outputPosition + frameOffset
                accumulator[outputIndex] += value * weight
                weights[outputIndex] += weight
            }

            // A completed synthesis frame is stable only after every candidate
            // and comparison sample that can affect its prefix exists. The next
            // frame begins at stableSynthesisFrameCount * synthesisHop, so no
            // future overlap can alter output before that boundary.
            if nominalInputPosition + searchRadius + compareLength <= input.count {
                stableSynthesisFrameCount = frameIndex + 1
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

        applyEdgeFade(
            samples: &output,
            policy: edgeFadePolicy
        )
        return MonoRenderResult(
            samples: output,
            stableFrameCount: min(
                normalizedCount,
                stableSynthesisFrameCount * synthesisHop
            )
        )
    }

    private static func bestInputPosition(
        input: [Float],
        output: [Float],
        weights: [Float],
        nominalInputPosition: Int,
        outputPosition: Int,
        frameSize: Int,
        searchRadius: Int,
        compareLength: Int
    ) -> Int {
        guard outputPosition > 0 else {
            return nominalInputPosition
        }

        let searchStart = max(0, nominalInputPosition - searchRadius)
        let searchEnd = min(
            max(0, input.count - 1),
            nominalInputPosition + searchRadius
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
                    (2.0 * Double.pi * Double(index)) /
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

    private static func applyEdgeFade(
        samples: inout [Float],
        policy: EdgeFadePolicy
    ) {
        guard policy != .none else {
            return
        }
        let fadeLength = min(
            maximumEdgeFadeFrameCount,
            samples.count / 8
        )
        guard fadeLength > 1 else {
            return
        }

        for index in 0..<fadeLength {
            let gain = Float(index) / Float(fadeLength)
            samples[index] *= gain
            if policy == .leadingAndTrailing {
                let tailIndex = samples.count - index - 1
                samples[tailIndex] *= gain
            }
        }
    }

    private static func clamp(_ value: Float) -> Float {
        guard value.isFinite else {
            return 0
        }
        return min(1, max(-1, value))
    }
}

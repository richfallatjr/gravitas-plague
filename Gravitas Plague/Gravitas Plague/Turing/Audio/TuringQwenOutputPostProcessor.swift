import AVFoundation
import Foundation

nonisolated enum TuringQwenOutputPostProcessor {
    private static let defaultRate = 0.85
    private static let disabledEnvironmentKey = "TURING_QWEN_OUTPUT_STRETCH_DISABLED"
    private static let rateEnvironmentKey = "TURING_QWEN_OUTPUT_STRETCH_RATE"

    static func processForPlayback(
        _ audio: TuringComputeGapGeneratedAudio,
        reason: String
    ) async -> TuringComputeGapGeneratedAudio {
        let rate = configuredRate
        guard shouldProcess(rate: rate) else {
            logBypassed(
                reason: reason,
                segmentIndex: audio.segmentIndex,
                rate: rate,
                sampleCount: audio.samples.count,
                sampleRate: audio.sampleRate,
                channelCount: audio.channelCount
            )
            return audio
        }

        let segmentIndex = audio.segmentIndex
        let sampleRate = audio.sampleRate
        let channelCount = audio.channelCount
        let samples = audio.samples

        let started = Date()
        let processedSamples = await Task.detached(priority: .userInitiated) {
            stretch(
                samples: samples,
                channelCount: Int(channelCount),
                rate: rate
            )
        }.value
        let elapsed = Date().timeIntervalSince(started)

        let inputDuration = durationSeconds(
            sampleCount: samples.count,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        let outputDuration = durationSeconds(
            sampleCount: processedSamples.count,
            sampleRate: sampleRate,
            channelCount: channelCount
        )

        print("""
        [TuringQwenPostProcess] output time stretch applied
          reason: \(reason)
          segmentIndex: \(segmentIndex)
          rate: \(String(format: "%.3f", rate))
          inputSampleCount: \(samples.count)
          outputSampleCount: \(processedSamples.count)
          inputDurationSeconds: \(String(format: "%.3f", inputDuration))
          outputDurationSeconds: \(String(format: "%.3f", outputDuration))
          processingSeconds: \(String(format: "%.3f", elapsed))
        """)

        return TuringComputeGapGeneratedAudio(
            segmentIndex: segmentIndex,
            samples: processedSamples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sourceText: audio.sourceText
        )
    }

    static func processForPlayback(
        _ audio: TuringComputeGapGeneratedAudio,
        policy: TuringQwenOutputProcessingPolicy,
        reason: String
    ) async -> TuringComputeGapGeneratedAudio {
        let rate = policy.playbackRate

        guard shouldProcess(rate: rate) else {
            logBypassed(
                reason: reason,
                segmentIndex: audio.segmentIndex,
                rate: rate,
                sampleCount: audio.samples.count,
                sampleRate: audio.sampleRate,
                channelCount: audio.channelCount
            )

            print("""
            [TuringQwenPostProcess] voice policy bypassed
              voiceID: \(policy.voiceID)
              rate: \(String(format: "%.3f", rate))
              segmentIndex: \(audio.segmentIndex)
            """)

            return audio
        }

        let segmentIndex = audio.segmentIndex
        let sampleRate = audio.sampleRate
        let channelCount = audio.channelCount
        let samples = audio.samples
        let started = Date()

        let processedSamples = await Task.detached(
            priority: .userInitiated
        ) {
            stretch(
                samples: samples,
                channelCount: Int(channelCount),
                rate: rate
            )
        }.value

        let elapsed = Date().timeIntervalSince(started)
        let inputDuration = durationSeconds(
            sampleCount: samples.count,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        let outputDuration = durationSeconds(
            sampleCount: processedSamples.count,
            sampleRate: sampleRate,
            channelCount: channelCount
        )

        print("""
        [TuringQwenPostProcess] voice policy applied
          voiceID: \(policy.voiceID)
          reason: \(reason)
          segmentIndex: \(segmentIndex)
          rate: \(String(format: "%.3f", rate))
          inputSampleCount: \(samples.count)
          outputSampleCount: \(processedSamples.count)
          inputDurationSeconds: \(String(format: "%.3f", inputDuration))
          outputDurationSeconds: \(String(format: "%.3f", outputDuration))
          processingSeconds: \(String(format: "%.3f", elapsed))
        """)

        return TuringComputeGapGeneratedAudio(
            segmentIndex: segmentIndex,
            samples: processedSamples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sourceText: audio.sourceText
        )
    }

    static func processSamplesForPlayback(
        samples: [Float],
        sampleRate: Int,
        channelCount: Int = 1,
        segmentIndex: Int,
        reason: String
    ) async -> [Float] {
        let rate = configuredRate
        guard shouldProcess(rate: rate) else {
            logBypassed(
                reason: reason,
                segmentIndex: segmentIndex,
                rate: rate,
                sampleCount: samples.count,
                sampleRate: Double(sampleRate),
                channelCount: AVAudioChannelCount(channelCount)
            )
            return samples
        }

        let started = Date()
        let processedSamples = await Task.detached(priority: .userInitiated) {
            stretch(
                samples: samples,
                channelCount: channelCount,
                rate: rate
            )
        }.value
        let elapsed = Date().timeIntervalSince(started)

        let inputDuration = durationSeconds(
            sampleCount: samples.count,
            sampleRate: Double(sampleRate),
            channelCount: AVAudioChannelCount(channelCount)
        )
        let outputDuration = durationSeconds(
            sampleCount: processedSamples.count,
            sampleRate: Double(sampleRate),
            channelCount: AVAudioChannelCount(channelCount)
        )

        print("""
        [TuringQwenPostProcess] output time stretch applied
          reason: \(reason)
          segmentIndex: \(segmentIndex)
          rate: \(String(format: "%.3f", rate))
          inputSampleCount: \(samples.count)
          outputSampleCount: \(processedSamples.count)
          inputDurationSeconds: \(String(format: "%.3f", inputDuration))
          outputDurationSeconds: \(String(format: "%.3f", outputDuration))
          processingSeconds: \(String(format: "%.3f", elapsed))
        """)

        return processedSamples
    }

    private static var configuredRate: Double {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment[rateEnvironmentKey],
           let parsed = Double(value),
           parsed > 0.25,
           parsed <= 2.0 {
            return parsed
        }
        return defaultRate
    }

    private static func shouldProcess(rate: Double) -> Bool {
        let disabled = ProcessInfo.processInfo.environment[disabledEnvironmentKey] ?? ""
        guard disabled != "1",
              disabled.lowercased() != "true" else {
            return false
        }

        return abs(rate - 1.0) > 0.001
    }

    private static func durationSeconds(
        sampleCount: Int,
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) -> Double {
        guard sampleRate > 0,
              channelCount > 0 else {
            return 0
        }
        return Double(sampleCount) / Double(channelCount) / sampleRate
    }

    private static func logBypassed(
        reason: String,
        segmentIndex: Int,
        rate: Double,
        sampleCount: Int,
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) {
        let disabled = ProcessInfo.processInfo.environment[disabledEnvironmentKey] ?? ""
        let duration = durationSeconds(
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
        print("""
        [TuringQwenPostProcess] output time stretch bypassed
          reason: \(reason)
          segmentIndex: \(segmentIndex)
          rate: \(String(format: "%.3f", rate))
          disabledEnv: \(disabled.isEmpty ? "<unset>" : disabled)
          sampleCount: \(sampleCount)
          durationSeconds: \(String(format: "%.3f", duration))
        """)
    }

    private static func stretch(
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
        let analysisHop = max(1, Int((Double(synthesisHop) * rate).rounded()))
        let searchRadius = max(32, min(frameSize / 4, analysisHop / 2))
        let targetFrameCount = max(
            input.count,
            Int(ceil(Double(input.count) / rate))
        )
        let estimatedFrameCount = targetFrameCount + frameSize * 4
        var accumulator = Array(repeating: Float(0), count: estimatedFrameCount)
        var weights = Array(repeating: Float(0), count: estimatedFrameCount)
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

            furthestWritten = max(furthestWritten, outputPosition + frameSize)
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
        let compareLength = min(frameSize / 2, max(64, frameSize - 256))
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

                let outputSample = Double(output[outputIndex] / weights[outputIndex])
                let inputSample = Double(sample(input, at: candidate + offset))
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
            Float(0.5 - 0.5 * cos((2.0 * Double.pi * Double(index)) / Double(length - 1)))
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
        accumulator.append(contentsOf: repeatElement(0, count: additionalCount))
        weights.append(contentsOf: repeatElement(0, count: additionalCount))
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

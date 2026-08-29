import Foundation

nonisolated enum TuringGeneratedSpeechAnalysisError: Error, Sendable, Equatable {
    case invalidSampleRate
    case invalidChannelCount
    case emptyAudio
    case invalidInterleavedCount
    case invalidTimeline
    case timelineOverflow
    case cancelled
    case deadlineExceeded
    case invalidTrack
    case nonfiniteResult
}

nonisolated struct TuringGeneratedSpeechAnalysisConfiguration: Sendable, Equatable {
    let featureWindowSeconds: Double
    let featureHopSeconds: Double
    let envelopeBucketRate: Int
    let floorPercentile: Float
    let ceilingPercentile: Float
    let minimumDynamicRangeDecibels: Float
    let absoluteFloorDecibels: Float
    let minimumCeilingDecibels: Float
    let gateOpenMinimumOffsetDecibels: Float
    let gateOpenDynamicRangeFraction: Float
    let gateCloseHysteresisDecibels: Float
    let attackSeconds: Double
    let releaseSeconds: Double
    let openConfirmationWindows: Int
    let closeConfirmationWindows: Int
    let smallMaximumEnergy: Float
    let roundEnergyRange: ClosedRange<Float>
    let roundMaximumZeroCrossing: Float
    let roundMaximumDifferenceRatio: Float
    let roundMinimumSustainSeconds: Double
    let roundMinimumSpacingSeconds: Double
    let teethEnergyRange: ClosedRange<Float>
    let teethMinimumZeroCrossing: Float
    let teethMinimumDifferenceRatio: Float
    let teethMinimumSustainSeconds: Double
    let teethMinimumSpacingSeconds: Double
    let frameRate: Int

    static let production = TuringGeneratedSpeechAnalysisConfiguration(
        featureWindowSeconds: 0.025,
        featureHopSeconds: 0.010,
        envelopeBucketRate: 10,
        floorPercentile: 0.20,
        ceilingPercentile: 0.90,
        minimumDynamicRangeDecibels: 12,
        absoluteFloorDecibels: -72,
        minimumCeilingDecibels: -24,
        gateOpenMinimumOffsetDecibels: 6,
        gateOpenDynamicRangeFraction: 0.28,
        gateCloseHysteresisDecibels: 3,
        attackSeconds: 0.035,
        releaseSeconds: 0.120,
        openConfirmationWindows: 2,
        closeConfirmationWindows: 5,
        smallMaximumEnergy: 0.30,
        roundEnergyRange: 0.30...0.88,
        roundMaximumZeroCrossing: 0.085,
        roundMaximumDifferenceRatio: 0.20,
        roundMinimumSustainSeconds: 0.160,
        roundMinimumSpacingSeconds: 0.400,
        teethEnergyRange: 0.24...0.90,
        teethMinimumZeroCrossing: 0.11,
        teethMinimumDifferenceRatio: 0.24,
        teethMinimumSustainSeconds: 0.120,
        teethMinimumSpacingSeconds: 0.300,
        frameRate: 60
    )

    var isValid: Bool {
        featureWindowSeconds > 0 && featureHopSeconds > 0 && envelopeBucketRate > 0 &&
        floorPercentile >= 0 && floorPercentile <= ceilingPercentile && ceilingPercentile <= 1 &&
        minimumDynamicRangeDecibels > 0 && gateCloseHysteresisDecibels >= 0 &&
        attackSeconds > 0 && releaseSeconds > 0 && openConfirmationWindows > 0 &&
        closeConfirmationWindows > 0 && smallMaximumEnergy >= 0 && smallMaximumEnergy <= 1 &&
        frameRate == 60
    }
}

nonisolated enum TuringGeneratedSpeechStatistics {
    static func nearestRankPercentile(sorted values: [Float], percentile: Float) -> Float? {
        guard !values.isEmpty else { return nil }
        let p = min(1, max(0, percentile))
        let rank = max(1, Int(ceil(Double(p) * Double(values.count))))
        return values[min(values.count - 1, rank - 1)]
    }
}

nonisolated struct TuringSanitizedMonoAudio: Sendable, Equatable {
    let samples: ContiguousArray<Float>
    let nonfiniteCount: Int
    let clippedCount: Int
}

nonisolated enum TuringGeneratedSpeechPCM {
    static func sanitizeAndDownmix(
        interleaved samples: [Float],
        channelCount: Int
    ) throws -> TuringSanitizedMonoAudio {
        guard channelCount > 0 else { throw TuringGeneratedSpeechAnalysisError.invalidChannelCount }
        guard !samples.isEmpty else { throw TuringGeneratedSpeechAnalysisError.emptyAudio }
        guard samples.count % channelCount == 0 else {
            throw TuringGeneratedSpeechAnalysisError.invalidInterleavedCount
        }
        let frameCount = samples.count / channelCount
        var mono = ContiguousArray<Float>()
        mono.reserveCapacity(frameCount)
        var nonfiniteCount = 0
        var clippedCount = 0
        for frame in 0..<frameCount {
            let base = frame * channelCount
            var sum: Float = 0
            for channel in 0..<channelCount {
                var value = samples[base + channel]
                if !value.isFinite { value = 0; nonfiniteCount += 1 }
                if value > 1 { value = 1; clippedCount += 1 }
                else if value < -1 { value = -1; clippedCount += 1 }
                sum += value
            }
            mono.append(sum / Float(channelCount))
        }
        return .init(samples: mono, nonfiniteCount: nonfiniteCount, clippedCount: clippedCount)
    }
}

nonisolated struct TuringRawSpeechFeature: Sendable, Equatable {
    let startSample: Int
    let endSample: Int
    let rms: Float
    let decibels: Float
    let peak: Float
    let zeroCrossingRate: Float
    let firstDifferenceRatio: Float
}

nonisolated enum TuringGeneratedSpeechFeatureExtractor {
    static func extract(
        mono: ContiguousArray<Float>,
        sampleRate: Int,
        configuration: TuringGeneratedSpeechAnalysisConfiguration,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> ContiguousArray<TuringRawSpeechFeature> {
        let windowSamples = max(1, Int((configuration.featureWindowSeconds * Double(sampleRate)).rounded()))
        let hopSamples = max(1, Int((configuration.featureHopSeconds * Double(sampleRate)).rounded()))
        var result = ContiguousArray<TuringRawSpeechFeature>()
        result.reserveCapacity(max(1, (mono.count + hopSamples - 1) / hopSamples))
        var start = 0
        var windowIndex = 0
        while start < mono.count {
            if windowIndex % 64 == 0 { try cancellationCheck() }
            let end = min(mono.count, start + windowSamples)
            var sumSquares: Double = 0
            var peak: Float = 0
            var crossings = 0
            var differenceSquares: Double = 0
            var prior = mono[start]
            var index = start
            while index < end {
                let value = mono[index]
                peak = max(peak, abs(value))
                sumSquares += Double(value) * Double(value)
                if index > start {
                    if (prior < 0 && value >= 0) || (prior >= 0 && value < 0) { crossings += 1 }
                    let difference = value - prior
                    differenceSquares += Double(difference) * Double(difference)
                }
                prior = value
                index += 1
            }
            let count = max(1, end - start)
            let rms = Float(sqrt(sumSquares / Double(count)))
            let decibels = 20 * log10(max(rms, 0.000_000_1))
            let crossingRate = count > 1 ? Float(crossings) / Float(count - 1) : 0
            let differenceRMS = count > 1 ? Float(sqrt(differenceSquares / Double(count - 1))) : 0
            let differenceRatio = min(1, max(0, differenceRMS / max(0.000_001, rms * 2)))
            guard rms.isFinite, decibels.isFinite, peak.isFinite,
                  crossingRate.isFinite, differenceRatio.isFinite else {
                throw TuringGeneratedSpeechAnalysisError.nonfiniteResult
            }
            result.append(.init(
                startSample: start,
                endSample: end,
                rms: rms,
                decibels: max(-140, decibels),
                peak: peak,
                zeroCrossingRate: crossingRate,
                firstDifferenceRatio: differenceRatio
            ))
            start += hopSamples
            windowIndex += 1
        }
        return result
    }
}

nonisolated struct TuringGeneratedSpeechThresholds: Sendable, Equatable {
    let floorDecibels: Float
    let ceilingDecibels: Float
    let gateOpenDecibels: Float
    let gateCloseDecibels: Float
}

nonisolated enum TuringGeneratedSpeechThresholdResolver {
    static func resolve(
        features: ContiguousArray<TuringRawSpeechFeature>,
        configuration: TuringGeneratedSpeechAnalysisConfiguration
    ) throws -> TuringGeneratedSpeechThresholds {
        var values = features.map(\.decibels)
        values.sort()
        guard let p20 = TuringGeneratedSpeechStatistics.nearestRankPercentile(
            sorted: values, percentile: configuration.floorPercentile
        ), let p90 = TuringGeneratedSpeechStatistics.nearestRankPercentile(
            sorted: values, percentile: configuration.ceilingPercentile
        ) else { throw TuringGeneratedSpeechAnalysisError.emptyAudio }
        let floor = max(configuration.absoluteFloorDecibels, p20)
        let ceiling = max(configuration.minimumCeilingDecibels, p90,
                          floor + configuration.minimumDynamicRangeDecibels)
        let range = max(configuration.minimumDynamicRangeDecibels, ceiling - floor)
        let openOffset = max(configuration.gateOpenMinimumOffsetDecibels,
                             range * configuration.gateOpenDynamicRangeFraction)
        let open = min(ceiling, floor + openOffset)
        return .init(
            floorDecibels: floor,
            ceilingDecibels: ceiling,
            gateOpenDecibels: open,
            gateCloseDecibels: open - configuration.gateCloseHysteresisDecibels
        )
    }
}

nonisolated struct TuringGeneratedSpeechAccentState: Sendable, Equatable {
    var continuousSpeechSamples = 0
    var samplesSinceRound = Int.max
    var samplesSinceTeeth = Int.max
}

nonisolated enum TuringGeneratedSpeechFrameExpander {
    static func expand(
        sampleRate: Int,
        sampleCount: Int,
        buckets: ContiguousArray<TuringSpeechAmplitudeEnvelopeBucket>,
        bucketRate: Int,
        frameRate: Int
    ) throws -> (poseBits: ContiguousArray<UInt8>, poseRuns: ContiguousArray<TuringGeneratedMouthPoseRun>) {
        let frameCount = try TuringGeneratedSpeechFrameTrack.frameCount(
            sampleCount: sampleCount, sampleRate: sampleRate, framesPerSecond: frameRate
        )
        guard !buckets.isEmpty, bucketRate > 0 else {
            throw TuringGeneratedSpeechAnalysisError.invalidTimeline
        }
        let priority: [TuringGeneratedMouthPose: Int] = [
            .rest: 0, .wide: 1, .small: 2, .round: 3, .teeth: 4
        ]
        var bits = ContiguousArray<UInt8>()
        bits.reserveCapacity(frameCount)
        var firstBucketIndex = 0
        for frame in 0..<frameCount {
            let start = (frame * sampleRate) / frameRate
            let end = min(sampleCount, ((frame + 1) * sampleRate) / frameRate)
            let center = start + max(0, end - start - 1) / 2
            while firstBucketIndex < buckets.count,
                  buckets[firstBucketIndex].endSample <= start {
                firstBucketIndex += 1
            }
            var overlapByPose: [TuringGeneratedMouthPose: Int] = [:]
            var centerPose: TuringGeneratedMouthPose?
            var bucketIndex = firstBucketIndex
            while bucketIndex < buckets.count, buckets[bucketIndex].startSample < end {
                let bucket = buckets[bucketIndex]
                let overlap = max(0, min(end, bucket.endSample) - max(start, bucket.startSample))
                overlapByPose[bucket.semanticPose, default: 0] += overlap
                if bucket.startSample <= center && center < bucket.endSample { centerPose = bucket.semanticPose }
                bucketIndex += 1
            }
            guard let maximum = overlapByPose.values.max() else {
                throw TuringGeneratedSpeechAnalysisError.invalidTimeline
            }
            let tied = overlapByPose.filter { $0.value == maximum }.map(\.key)
            let selected: TuringGeneratedMouthPose
            if let centerPose, tied.contains(centerPose) { selected = centerPose }
            else { selected = tied.max { priority[$0, default: 0] < priority[$1, default: 0] } ?? .rest }
            bits.append(selected.rawValue)
        }
        var runs = ContiguousArray<TuringGeneratedMouthPoseRun>()
        for (index, raw) in bits.enumerated() {
            guard let pose = TuringGeneratedMouthPose(rawValue: raw) else {
                throw TuringGeneratedSpeechAnalysisError.invalidTrack
            }
            if let last = runs.last, last.pose == pose {
                runs[runs.count - 1] = .init(
                    startFrame: last.startFrame, endFrameExclusive: index + 1, pose: pose
                )
            } else {
                runs.append(.init(startFrame: index, endFrameExclusive: index + 1, pose: pose))
            }
        }
        return (bits, runs)
    }
}

nonisolated protocol TuringGeneratedSpeechAnalyzing: Sendable {
    func analyze(
        processedAudio: [Float],
        sampleRate: Int,
        channelCount: Int,
        deadline: ContinuousClock.Instant?,
        cancellationToken: TuringGeneratedSpeechAnalysisCancellationToken?
    ) throws -> TuringGeneratedSpeechVisualAnalysis
}

nonisolated struct TuringGeneratedSpeechAnalyzer: TuringGeneratedSpeechAnalyzing, Sendable {
    let configuration: TuringGeneratedSpeechAnalysisConfiguration

    init(configuration: TuringGeneratedSpeechAnalysisConfiguration = .production) {
        self.configuration = configuration
    }

    func analyze(
        processedAudio: [Float],
        sampleRate: Int,
        channelCount: Int,
        deadline: ContinuousClock.Instant?,
        cancellationToken: TuringGeneratedSpeechAnalysisCancellationToken? = nil
    ) throws -> TuringGeneratedSpeechVisualAnalysis {
        let started = ContinuousClock.now
        guard sampleRate > 0 else { throw TuringGeneratedSpeechAnalysisError.invalidSampleRate }
        guard configuration.isValid else { throw TuringGeneratedSpeechAnalysisError.invalidTimeline }
        let cancellationCheck: @Sendable () throws -> Void = {
            if Task.isCancelled || cancellationToken?.isCancelled == true {
                throw TuringGeneratedSpeechAnalysisError.cancelled
            }
            if let deadline, ContinuousClock.now >= deadline {
                throw TuringGeneratedSpeechAnalysisError.deadlineExceeded
            }
        }
        try cancellationCheck()
        let mono = try TuringGeneratedSpeechPCM.sanitizeAndDownmix(
            interleaved: processedAudio, channelCount: channelCount
        )
        let raw = try TuringGeneratedSpeechFeatureExtractor.extract(
            mono: mono.samples,
            sampleRate: sampleRate,
            configuration: configuration,
            cancellationCheck: cancellationCheck
        )
        let thresholds = try TuringGeneratedSpeechThresholdResolver.resolve(
            features: raw, configuration: configuration
        )
        let windows = try normalizeAndGate(
            raw: raw,
            thresholds: thresholds,
            cancellationCheck: cancellationCheck
        )
        let buckets = try makeBucketsAndClassify(
            windows: windows,
            sampleRate: sampleRate,
            sampleCount: mono.samples.count,
            cancellationCheck: cancellationCheck
        )
        let expanded = try TuringGeneratedSpeechFrameExpander.expand(
            sampleRate: sampleRate,
            sampleCount: mono.samples.count,
            buckets: buckets,
            bucketRate: configuration.envelopeBucketRate,
            frameRate: configuration.frameRate
        )
        let completed = ContinuousClock.now
        let diagnostics = TuringGeneratedSpeechAnalysisDiagnostics(
            sourceSampleRate: sampleRate,
            sourceChannelCount: channelCount,
            interleavedSampleCount: processedAudio.count,
            monoSampleCount: mono.samples.count,
            sanitizedNonfiniteSampleCount: mono.nonfiniteCount,
            clippedSampleCount: mono.clippedCount,
            featureWindowSamples: max(1, Int((configuration.featureWindowSeconds * Double(sampleRate)).rounded())),
            featureHopSamples: max(1, Int((configuration.featureHopSeconds * Double(sampleRate)).rounded())),
            featureWindowCount: windows.count,
            envelopeBucketCount: buckets.count,
            floorDecibels: thresholds.floorDecibels,
            ceilingDecibels: thresholds.ceilingDecibels,
            gateOpenDecibels: thresholds.gateOpenDecibels,
            gateCloseDecibels: thresholds.gateCloseDecibels,
            speechBucketCount: buckets.filter(\.speechActive).count,
            silenceBucketCount: buckets.filter { !$0.speechActive }.count,
            roundAccentCount: buckets.filter { $0.semanticPose == .round }.count,
            teethAccentCount: buckets.filter { $0.semanticPose == .teeth }.count,
            generatedFrameCount: expanded.poseBits.count,
            poseRunCount: expanded.poseRuns.count,
            analysisNanoseconds: Self.nanoseconds(started.duration(to: completed)),
            deadlineExceeded: false
        )
        let envelope = TuringSpeechAmplitudeEnvelope(
            sampleRate: sampleRate,
            sampleCount: mono.samples.count,
            bucketRate: configuration.envelopeBucketRate,
            buckets: buckets,
            diagnostics: diagnostics
        )
        let track = try TuringGeneratedSpeechFrameTrack(
            sampleRate: sampleRate,
            sampleCount: mono.samples.count,
            framesPerSecond: configuration.frameRate,
            poseBits: expanded.poseBits,
            poseRuns: expanded.poseRuns
        )
        return .init(envelope: envelope, frameTrack: track)
    }

    private func normalizeAndGate(
        raw: ContiguousArray<TuringRawSpeechFeature>,
        thresholds: TuringGeneratedSpeechThresholds,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> ContiguousArray<TuringSpeechFeatureWindow> {
        var result = ContiguousArray<TuringSpeechFeatureWindow>()
        result.reserveCapacity(raw.count)
        let dt = configuration.featureHopSeconds
        let attack = Float(1 - exp(-dt / configuration.attackSeconds))
        let release = Float(1 - exp(-dt / configuration.releaseSeconds))
        let range = max(configuration.minimumDynamicRangeDecibels,
                        thresholds.ceilingDecibels - thresholds.floorDecibels)
        var smoothed: Float = 0
        var isOpen = false
        var above = 0
        var below = 0
        for (index, feature) in raw.enumerated() {
            if index % 64 == 0 { try cancellationCheck() }
            let target = min(1, max(0, (feature.decibels - thresholds.floorDecibels) / range))
            smoothed += (target - smoothed) * (target > smoothed ? attack : release)
            if isOpen {
                if feature.decibels < thresholds.gateCloseDecibels { below += 1 } else { below = 0 }
                if below >= configuration.closeConfirmationWindows { isOpen = false; above = 0 }
            } else {
                if feature.decibels >= thresholds.gateOpenDecibels { above += 1 } else { above = 0 }
                if above >= configuration.openConfirmationWindows { isOpen = true; below = 0 }
            }
            result.append(.init(
                startSample: feature.startSample,
                endSample: feature.endSample,
                rms: feature.rms,
                decibelsFullScale: feature.decibels,
                peak: feature.peak,
                zeroCrossingRate: feature.zeroCrossingRate,
                firstDifferenceRatio: feature.firstDifferenceRatio,
                smoothedEnergy: smoothed,
                speechActive: isOpen
            ))
        }
        return result
    }

    private func makeBucketsAndClassify(
        windows: ContiguousArray<TuringSpeechFeatureWindow>,
        sampleRate: Int,
        sampleCount: Int,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> ContiguousArray<TuringSpeechAmplitudeEnvelopeBucket> {
        let rate = configuration.envelopeBucketRate
        let product = sampleCount.multipliedReportingOverflow(by: rate)
        guard !product.overflow else { throw TuringGeneratedSpeechAnalysisError.timelineOverflow }
        let numerator = product.partialValue.addingReportingOverflow(sampleRate - 1)
        guard !numerator.overflow else { throw TuringGeneratedSpeechAnalysisError.timelineOverflow }
        let count = numerator.partialValue / sampleRate
        var buckets = ContiguousArray<TuringSpeechAmplitudeEnvelopeBucket>()
        buckets.reserveCapacity(count)
        var accent = TuringGeneratedSpeechAccentState()
        let roundSustain = Int((configuration.roundMinimumSustainSeconds * Double(sampleRate)).rounded())
        let roundSpacing = Int((configuration.roundMinimumSpacingSeconds * Double(sampleRate)).rounded())
        let teethSustain = Int((configuration.teethMinimumSustainSeconds * Double(sampleRate)).rounded())
        let teethSpacing = Int((configuration.teethMinimumSpacingSeconds * Double(sampleRate)).rounded())
        var firstWindowIndex = 0
        for bucketIndex in 0..<count {
            if bucketIndex % 64 == 0 { try cancellationCheck() }
            let start = (bucketIndex * sampleRate) / rate
            let end = min(sampleCount, ((bucketIndex + 1) * sampleRate) / rate)
            var totalOverlap = 0
            var speechOverlap = 0
            var energy: Float = 0
            var zcr: Float = 0
            var difference: Float = 0
            while firstWindowIndex < windows.count,
                  windows[firstWindowIndex].endSample <= start {
                firstWindowIndex += 1
            }
            var windowIndex = firstWindowIndex
            while windowIndex < windows.count, windows[windowIndex].startSample < end {
                let window = windows[windowIndex]
                let overlap = max(0, min(end, window.endSample) - max(start, window.startSample))
                if overlap > 0 {
                    totalOverlap += overlap
                    if window.speechActive { speechOverlap += overlap }
                    let weight = Float(overlap)
                    energy += window.smoothedEnergy * weight
                    zcr += window.zeroCrossingRate * weight
                    difference += window.firstDifferenceRatio * weight
                }
                windowIndex += 1
            }
            let denominator = Float(max(1, totalOverlap))
            let normalizedEnergy = min(1, max(0, energy / denominator))
            let meanZCR = min(1, max(0, zcr / denominator))
            let meanDifference = min(1, max(0, difference / denominator))
            let coverage = min(1, max(0, Float(speechOverlap) / denominator))
            let speechActive = coverage >= 0.25
            let duration = max(1, end - start)
            if speechActive {
                accent.continuousSpeechSamples = min(Int.max, accent.continuousSpeechSamples + duration)
                accent.samplesSinceRound = Self.saturatingAdd(accent.samplesSinceRound, duration)
                accent.samplesSinceTeeth = Self.saturatingAdd(accent.samplesSinceTeeth, duration)
            } else {
                accent.continuousSpeechSamples = 0
            }
            var pose: TuringGeneratedMouthPose = speechActive
                ? (normalizedEnergy < configuration.smallMaximumEnergy ? .small : .wide)
                : .rest
            if speechActive,
               configuration.teethEnergyRange.contains(normalizedEnergy),
               meanZCR >= configuration.teethMinimumZeroCrossing,
               meanDifference >= configuration.teethMinimumDifferenceRatio,
               accent.continuousSpeechSamples >= teethSustain,
               accent.samplesSinceTeeth >= teethSpacing {
                pose = .teeth
                accent.samplesSinceTeeth = 0
            } else if speechActive,
                      configuration.roundEnergyRange.contains(normalizedEnergy),
                      meanZCR <= configuration.roundMaximumZeroCrossing,
                      meanDifference <= configuration.roundMaximumDifferenceRatio,
                      accent.continuousSpeechSamples >= roundSustain,
                      accent.samplesSinceRound >= roundSpacing {
                pose = .round
                accent.samplesSinceRound = 0
            }
            buckets.append(.init(
                bucketIndex: bucketIndex,
                startSample: start,
                endSample: end,
                normalizedEnergy: normalizedEnergy,
                meanZeroCrossingRate: meanZCR,
                meanFirstDifferenceRatio: meanDifference,
                speechCoverage: coverage,
                speechActive: speechActive,
                semanticPose: pose
            ))
        }
        return buckets
    }

    private static func saturatingAdd(_ value: Int, _ increment: Int) -> Int {
        guard value != Int.max else { return Int.max }
        let result = value.addingReportingOverflow(increment)
        return result.overflow ? Int.max : result.partialValue
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanos = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        let multiplied = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !multiplied.overflow else { return UInt64.max }
        let sum = multiplied.partialValue.addingReportingOverflow(nanos)
        return sum.overflow ? UInt64.max : sum.partialValue
    }
}

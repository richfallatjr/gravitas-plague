import Foundation

nonisolated enum MindEyeVariantIndexSelector {
    static func select(
        count: Int,
        avoiding previous: Int?,
        random: inout MindEyeDeterministicRandom
    ) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1, let previous, (0..<count).contains(previous) else {
            return count == 1 ? 0 : random.nextInt(in: 0...(count - 1))
        }
        let raw = random.nextInt(in: 0...(count - 2))
        return raw >= previous ? raw + 1 : raw
    }
}

nonisolated struct MindEyeBlinkScheduler: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case openWaiting
        case closed(pendingSecondBlink: Bool)
        case secondBlinkWaiting
        case disabled
    }

    private(set) var phase: Phase
    private(set) var eyeSelection: MindEyeEyeSelection
    private(set) var blinkCount: UInt64 = 0
    private var remainingSeconds: Float
    private var lastOpenVariant: Int?
    private var lastClosedVariant: Int?

    init(
        tuning: MindEyeResolvedBlinkTuning,
        openVariantCount: Int,
        closedVariantCount: Int,
        streams: inout MindEyeMotionRandomStreams
    ) {
        let openIndex = MindEyeVariantIndexSelector.select(
            count: openVariantCount,
            avoiding: nil,
            random: &streams.openEyes
        ) ?? 0
        lastOpenVariant = openIndex
        eyeSelection = .open(variantIndex: openIndex)
        guard closedVariantCount > 0 else {
            phase = .disabled
            remainingSeconds = .greatestFiniteMagnitude
            return
        }
        phase = .openWaiting
        remainingSeconds = Self.nextOrdinaryInterval(
            tuning: tuning,
            random: &streams.blink
        )
    }

    mutating func advance(
        deltaTime: Float,
        tuning: MindEyeResolvedBlinkTuning,
        openVariantCount: Int,
        closedVariantCount: Int,
        streams: inout MindEyeMotionRandomStreams
    ) {
        if case .disabled = phase { return }
        var remainingDelta = max(0, deltaTime)
        var transitionGuard = 0
        while remainingDelta > 0, transitionGuard < 5 {
            transitionGuard += 1
            let consumed = min(remainingDelta, remainingSeconds)
            remainingSeconds -= consumed
            remainingDelta -= consumed
            guard remainingSeconds <= 0.000_001 else { continue }
            switch phase {
            case .openWaiting:
                guard let closedIndex = MindEyeVariantIndexSelector.select(
                    count: closedVariantCount,
                    avoiding: lastClosedVariant,
                    random: &streams.closedEyes
                ) else {
                    phase = .disabled
                    remainingSeconds = .greatestFiniteMagnitude
                    return
                }
                lastClosedVariant = closedIndex
                eyeSelection = .closed(variantIndex: closedIndex)
                blinkCount &+= 1
                let pendingSecond = streams.blink.chance(
                    tuning.doubleBlinkProbability
                )
                phase = .closed(pendingSecondBlink: pendingSecond)
                remainingSeconds = Self.nextClosedDuration(
                    tuning: tuning,
                    random: &streams.blink
                )
            case .closed(let pendingSecond):
                let openIndex = MindEyeVariantIndexSelector.select(
                    count: openVariantCount,
                    avoiding: lastOpenVariant,
                    random: &streams.openEyes
                ) ?? 0
                lastOpenVariant = openIndex
                eyeSelection = .open(variantIndex: openIndex)
                if pendingSecond {
                    phase = .secondBlinkWaiting
                    remainingSeconds = streams.blink.nextFloat(
                        in: tuning.doubleBlinkGapSeconds
                    )
                } else {
                    phase = .openWaiting
                    remainingSeconds = Self.nextOrdinaryInterval(
                        tuning: tuning,
                        random: &streams.blink
                    )
                }
            case .secondBlinkWaiting:
                guard let closedIndex = MindEyeVariantIndexSelector.select(
                    count: closedVariantCount,
                    avoiding: lastClosedVariant,
                    random: &streams.closedEyes
                ) else {
                    phase = .disabled
                    remainingSeconds = .greatestFiniteMagnitude
                    return
                }
                lastClosedVariant = closedIndex
                eyeSelection = .closed(variantIndex: closedIndex)
                blinkCount &+= 1
                phase = .closed(pendingSecondBlink: false)
                remainingSeconds = Self.nextClosedDuration(
                    tuning: tuning,
                    random: &streams.blink
                )
            case .disabled:
                return
            }
        }
    }

    private static func nextOrdinaryInterval(
        tuning: MindEyeResolvedBlinkTuning,
        random: inout MindEyeDeterministicRandom
    ) -> Float {
        let hard = MindEyeResolvedBlinkTuning.hardScheduleBounds
        let lower = min(
            hard.upperBound,
            max(hard.lowerBound, tuning.ordinaryIntervalSeconds.lowerBound)
        )
        let upper = min(
            hard.upperBound,
            max(lower, tuning.ordinaryIntervalSeconds.upperBound)
        )
        return lower + (upper - lower) * random.centerBiasedUnit()
    }

    private static func nextClosedDuration(
        tuning: MindEyeResolvedBlinkTuning,
        random: inout MindEyeDeterministicRandom
    ) -> Float {
        Float(random.nextInt(in: tuning.closedReferenceFrames)) /
            tuning.referenceFrameRate
    }
}

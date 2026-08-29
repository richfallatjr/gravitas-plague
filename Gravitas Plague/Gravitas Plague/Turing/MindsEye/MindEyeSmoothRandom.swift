import Foundation
import simd

nonisolated enum MindEyeSmootherstep {
    static func evaluate(_ value: Float) -> Float {
        let u = min(1, max(0, value))
        return u * u * u * (u * (u * 6 - 15) + 10)
    }
}

nonisolated struct MindEyeDriftChannel: Sendable, Equatable {
    private(set) var current = SIMD4<Float>.zero
    private var start = SIMD4<Float>.zero
    private var target = SIMD4<Float>.zero
    private var elapsed: Float = 0
    private var duration: Float = 0
    private var holdRemaining: Float = 0

    mutating func advance(
        deltaTime: Float,
        random: inout MindEyeDeterministicRandom,
        transitionRange: ClosedRange<Float>,
        holdRange: ClosedRange<Float>
    ) {
        var remaining = max(0, deltaTime)
        var transitionGuard = 0
        while remaining > 0, transitionGuard < 4 {
            transitionGuard += 1
            if holdRemaining > 0 {
                let consumed = min(remaining, holdRemaining)
                holdRemaining -= consumed
                remaining -= consumed
                continue
            }
            if duration <= 0 {
                start = current
                target = SIMD4<Float>(
                    random.centerBiasedSigned(),
                    random.centerBiasedSigned(),
                    random.centerBiasedSigned(),
                    random.centerBiasedUnit()
                )
                elapsed = 0
                duration = max(0.001, random.nextFloat(in: transitionRange))
            }
            let consumed = min(remaining, max(0, duration - elapsed))
            elapsed += consumed
            remaining -= consumed
            let smooth = MindEyeSmootherstep.evaluate(elapsed / duration)
            current = simd_mix(start, target, SIMD4<Float>(repeating: smooth))
            if elapsed >= duration - 0.000_001 {
                current = target
                duration = 0
                elapsed = 0
                holdRemaining = random.nextFloat(in: holdRange)
            }
        }
    }
}

nonisolated struct MindEyeSubjectChannel: Sendable, Equatable {
    private(set) var current = SIMD3<Float>.zero
    private var start = SIMD3<Float>.zero
    private var target = SIMD3<Float>.zero
    private var elapsed: Float = 0
    private var duration: Float = 0
    private var holdRemaining: Float = 0

    mutating func advance(
        deltaTime: Float,
        random: inout MindEyeDeterministicRandom,
        transitionRange: ClosedRange<Float>,
        holdRange: ClosedRange<Float>
    ) {
        var remaining = max(0, deltaTime)
        var transitionGuard = 0
        while remaining > 0, transitionGuard < 4 {
            transitionGuard += 1
            if holdRemaining > 0 {
                let consumed = min(remaining, holdRemaining)
                holdRemaining -= consumed
                remaining -= consumed
                continue
            }
            if duration <= 0 {
                start = current
                target = SIMD3<Float>(
                    random.centerBiasedSigned(),
                    random.centerBiasedSigned(),
                    random.centerBiasedSigned()
                )
                elapsed = 0
                duration = max(0.001, random.nextFloat(in: transitionRange))
            }
            let consumed = min(remaining, max(0, duration - elapsed))
            elapsed += consumed
            remaining -= consumed
            let smooth = MindEyeSmootherstep.evaluate(elapsed / duration)
            current = simd_mix(start, target, SIMD3<Float>(repeating: smooth))
            if elapsed >= duration - 0.000_001 {
                current = target
                duration = 0
                elapsed = 0
                holdRemaining = random.nextFloat(in: holdRange)
            }
        }
    }
}

nonisolated struct MindEyeGripCorrectionChannel: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case waiting, onset, settling }

    private(set) var current = SIMD3<Float>.zero
    private(set) var correctionCount: UInt64 = 0
    private var phase: Phase = .waiting
    private var target = SIMD3<Float>.zero
    private var elapsed: Float = 0
    private var duration: Float = 0
    private var waitingRemaining: Float = 0

    init(
        random: inout MindEyeDeterministicRandom,
        waitingRange: ClosedRange<Float>
    ) {
        waitingRemaining = random.nextFloat(in: waitingRange)
    }

    mutating func advance(
        deltaTime: Float,
        random: inout MindEyeDeterministicRandom,
        waitingRange: ClosedRange<Float>,
        onsetRange: ClosedRange<Float>,
        settleRange: ClosedRange<Float>
    ) {
        var remaining = max(0, deltaTime)
        var transitionGuard = 0
        while remaining > 0, transitionGuard < 5 {
            transitionGuard += 1
            switch phase {
            case .waiting:
                let consumed = min(remaining, waitingRemaining)
                waitingRemaining -= consumed
                remaining -= consumed
                if waitingRemaining <= 0.000_001 {
                    target = SIMD3<Float>(
                        random.centerBiasedSigned(),
                        random.centerBiasedSigned(),
                        random.centerBiasedSigned()
                    )
                    elapsed = 0
                    duration = max(0.001, random.nextFloat(in: onsetRange))
                    phase = .onset
                    correctionCount &+= 1
                }
            case .onset:
                let consumed = min(remaining, max(0, duration - elapsed))
                elapsed += consumed
                remaining -= consumed
                current = target * MindEyeSmootherstep.evaluate(elapsed / duration)
                if elapsed >= duration - 0.000_001 {
                    current = target
                    elapsed = 0
                    duration = max(0.001, random.nextFloat(in: settleRange))
                    phase = .settling
                }
            case .settling:
                let consumed = min(remaining, max(0, duration - elapsed))
                elapsed += consumed
                remaining -= consumed
                current = target * (1 - MindEyeSmootherstep.evaluate(elapsed / duration))
                if elapsed >= duration - 0.000_001 {
                    current = .zero
                    elapsed = 0
                    duration = 0
                    waitingRemaining = random.nextFloat(in: waitingRange)
                    phase = .waiting
                }
            }
        }
    }
}

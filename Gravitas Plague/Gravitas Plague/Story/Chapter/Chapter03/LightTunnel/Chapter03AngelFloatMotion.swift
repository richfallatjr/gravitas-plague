import Foundation
import simd

struct Chapter03AngelFloatMotion: Sendable {
    static let maxOffsetMeters: Float = 0.3048
    static let minimumSegmentDurationSeconds: TimeInterval = 6
    static let maximumSegmentDurationSeconds: TimeInterval = 10

    private static let minimumTargetRadiusMeters: Float = 0.0762
    private static let minimumTargetTravelMeters: Float = 0.1016

    private var randomState: UInt64
    private var segmentStartOffsetMeters: SIMD3<Float>
    private var segmentTargetOffsetMeters: SIMD3<Float>
    private var segmentElapsedSeconds: TimeInterval
    private var segmentDurationSeconds: TimeInterval

    private(set) var offsetMeters: SIMD3<Float>

    init(seed: UInt64) {
        randomState = seed
        segmentStartOffsetMeters = .zero
        segmentTargetOffsetMeters = .zero
        segmentElapsedSeconds = 0
        segmentDurationSeconds = Self.minimumSegmentDurationSeconds
        offsetMeters = .zero
        beginNextSegment(from: .zero)
    }

    mutating func update(deltaTime: TimeInterval) -> SIMD3<Float> {
        guard deltaTime.isFinite, deltaTime > 0 else {
            return offsetMeters
        }

        var remainingSeconds = deltaTime
        while remainingSeconds > 0 {
            let segmentRemainingSeconds = max(
                0,
                segmentDurationSeconds - segmentElapsedSeconds
            )
            if remainingSeconds >= segmentRemainingSeconds {
                offsetMeters = segmentTargetOffsetMeters
                remainingSeconds -= segmentRemainingSeconds
                beginNextSegment(from: segmentTargetOffsetMeters)
                continue
            }

            segmentElapsedSeconds += remainingSeconds
            remainingSeconds = 0
            let linearProgress = Float(
                segmentElapsedSeconds / segmentDurationSeconds
            )
            let easedProgress = smootherstep(linearProgress)
            offsetMeters = simd_mix(
                segmentStartOffsetMeters,
                segmentTargetOffsetMeters,
                SIMD3<Float>(repeating: easedProgress)
            )
        }

        return offsetMeters
    }

    private mutating func beginNextSegment(from start: SIMD3<Float>) {
        segmentStartOffsetMeters = start
        segmentTargetOffsetMeters = nextTarget(awayFrom: start)
        segmentElapsedSeconds = 0
        let minimumDuration = Self.minimumSegmentDurationSeconds
        let maximumDuration = Self.maximumSegmentDurationSeconds
        segmentDurationSeconds = randomTimeInterval(
            in: minimumDuration...maximumDuration
        )
    }

    private mutating func nextTarget(
        awayFrom currentOffset: SIMD3<Float>
    ) -> SIMD3<Float> {
        for _ in 0..<8 {
            let candidate = randomOffsetInsideLimit()
            if simd_distance(candidate, currentOffset) >=
                Self.minimumTargetTravelMeters {
                return candidate
            }
        }

        let fallbackDirection: SIMD3<Float>
        if simd_length_squared(currentOffset) > 0.000_001 {
            fallbackDirection = -simd_normalize(currentOffset)
        } else {
            fallbackDirection = SIMD3<Float>(0, 1, 0)
        }
        return fallbackDirection * Self.minimumTargetRadiusMeters
    }

    private mutating func randomOffsetInsideLimit() -> SIMD3<Float> {
        let azimuth = 2 * Float.pi * nextUnitFloat()
        let vertical = 2 * nextUnitFloat() - 1
        let horizontal = sqrt(max(0, 1 - vertical * vertical))
        let direction = SIMD3<Float>(
            horizontal * cos(azimuth),
            vertical,
            horizontal * sin(azimuth)
        )
        let radiusProgress = nextUnitFloat()
        let radius = Self.minimumTargetRadiusMeters +
            (Self.maxOffsetMeters - Self.minimumTargetRadiusMeters) *
            radiusProgress
        return direction * radius
    }

    private mutating func randomTimeInterval(
        in range: ClosedRange<TimeInterval>
    ) -> TimeInterval {
        range.lowerBound +
            (range.upperBound - range.lowerBound) * Double(nextUnitFloat())
    }

    private mutating func nextUnitFloat() -> Float {
        randomState &+= 0x9E37_79B9_7F4A_7C15
        var value = randomState
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Float(value >> 40) / Float(1 << 24)
    }

    private func smootherstep(_ value: Float) -> Float {
        let bounded = min(max(value, 0), 1)
        return bounded * bounded * bounded *
            (bounded * (bounded * 6 - 15) + 10)
    }
}

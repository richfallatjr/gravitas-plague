import Foundation
import simd

actor HeadStillnessDetector {
    struct Configuration: Sendable, Equatable {
        let requiredStableSeconds: Double
        let translationToleranceMeters: Float
        let rotationToleranceRadians: Float
        let trackingLossGraceSeconds: Double
    }

    struct Sample: Sendable {
        let timestampSeconds: TimeInterval
        let transform: simd_float4x4?
        let isTracked: Bool
    }

    enum Event: Sendable, Equatable {
        case baselineEstablished
        case progress(seconds: Double, fraction: Double)
        case movement
        case trackingPaused
        case trackingResumed
        case completed
    }

    private let configuration: Configuration
    private var baseline: simd_float4x4?
    private var stableStartSeconds: TimeInterval?
    private var trackingLossStartSeconds: TimeInterval?
    private var completed = false

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func reset() {
        baseline = nil
        stableStartSeconds = nil
        trackingLossStartSeconds = nil
        completed = false
    }

    func ingest(_ sample: Sample) -> Event? {
        guard !completed else { return nil }

        guard sample.isTracked, let transform = sample.transform else {
            if trackingLossStartSeconds == nil {
                trackingLossStartSeconds = sample.timestampSeconds
            }
            return .trackingPaused
        }

        if trackingLossStartSeconds != nil {
            trackingLossStartSeconds = nil
            baseline = transform
            stableStartSeconds = sample.timestampSeconds
            return .trackingResumed
        }

        guard let baseline else {
            self.baseline = transform
            stableStartSeconds = sample.timestampSeconds
            return .baselineEstablished
        }

        let translation = simd_distance(
            Self.translation(of: baseline),
            Self.translation(of: transform)
        )
        let rotation = Self.shortestQuaternionAngle(
            Self.rotation(of: baseline),
            Self.rotation(of: transform)
        )

        guard translation <= configuration.translationToleranceMeters,
              rotation <= configuration.rotationToleranceRadians else {
            self.baseline = transform
            stableStartSeconds = sample.timestampSeconds
            return .movement
        }

        guard let stableStartSeconds else {
            self.stableStartSeconds = sample.timestampSeconds
            return .baselineEstablished
        }

        let elapsed = max(0, sample.timestampSeconds - stableStartSeconds)
        if elapsed >= configuration.requiredStableSeconds {
            completed = true
            return .completed
        }
        return .progress(
            seconds: elapsed,
            fraction: min(1, elapsed / configuration.requiredStableSeconds)
        )
    }

    private static func translation(of matrix: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }

    private static func rotation(of matrix: simd_float4x4) -> simd_quatf {
        simd_normalize(simd_quatf(matrix))
    }

    private static func shortestQuaternionAngle(
        _ lhs: simd_quatf,
        _ rhs: simd_quatf
    ) -> Float {
        let dot = min(1, max(-1, abs(simd_dot(lhs.vector, rhs.vector))))
        return 2 * acos(dot)
    }
}

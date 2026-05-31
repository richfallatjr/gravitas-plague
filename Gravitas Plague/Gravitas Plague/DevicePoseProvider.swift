import ARKit
import Foundation
import QuartzCore
import simd

struct PhaseOneSpawnPose: Equatable {
    let headPosition: SIMD3<Float>
    let headForward: SIMD3<Float>

    static let fallback = PhaseOneSpawnPose(
        headPosition: SIMD3<Float>(0, 0, 0),
        headForward: SIMD3<Float>(0, 0, -1)
    )
}

@MainActor
final class DevicePoseProvider {
    private let session = ARKitSession()
    private let worldTrackingProvider = WorldTrackingProvider()

    private var isRunning = false

    func start() async {
        guard WorldTrackingProvider.isSupported else {
            isRunning = false
            return
        }

        do {
            try await session.run([worldTrackingProvider])
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        guard isRunning else { return }
        session.stop()
        isRunning = false
    }

    func currentPoseOrFallback() -> PhaseOneSpawnPose {
        currentPose() ?? .fallback
    }

    func currentPose() -> PhaseOneSpawnPose? {
        guard isRunning else { return nil }

        guard let deviceAnchor = worldTrackingProvider.queryDeviceAnchor(
            atTimestamp: CACurrentMediaTime()
        ) else {
            return nil
        }

        let matrix = deviceAnchor.originFromAnchorTransform

        let headPosition = SIMD3<Float>(
            matrix.columns.3.x,
            matrix.columns.3.y,
            matrix.columns.3.z
        )

        let rawForward = -SIMD3<Float>(
            matrix.columns.2.x,
            0,
            matrix.columns.2.z
        )

        let headForward = PhaseOneMath.normalizedOrFallback(
            rawForward,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        return PhaseOneSpawnPose(
            headPosition: headPosition,
            headForward: headForward
        )
    }
}

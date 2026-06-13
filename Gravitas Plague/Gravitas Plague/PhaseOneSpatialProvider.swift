import ARKit
import Foundation
import QuartzCore
import simd

struct PhaseOneSpawnPose: Equatable {
    let headPosition: SIMD3<Float>
    let headForward: SIMD3<Float>

    static let fallback = PhaseOneSpawnPose(
        headPosition: SIMD3<Float>(0, 1.45, 0),
        headForward: SIMD3<Float>(0, 0, -1)
    )
}

@MainActor
final class PhaseOneSpatialProvider {
    private let session = ARKitSession()
    private let worldTrackingProvider = WorldTrackingProvider()
    private let planeDetectionProvider = PlaneDetectionProvider(alignments: [.horizontal, .vertical])

    private var isRunning = false
    private var isPlaneDetectionRunning = false
    private var planeUpdateTask: Task<Void, Never>?

    private var knownHorizontalPlaneYsByID: [UUID: Float] = [:]

    var onPlaneAnchorUpdate: ((AnchorUpdate<PlaneAnchor>) -> Void)?

    func start() async {
        guard WorldTrackingProvider.isSupported else {
            isRunning = false
            return
        }

        do {
            if PlaneDetectionProvider.isSupported {
                let authorization = await session.requestAuthorization(for: [.worldSensing])
                let worldSensingAllowed = authorization[.worldSensing] == .allowed

                if worldSensingAllowed {
                    let providers: [any DataProvider] = [
                        worldTrackingProvider,
                        planeDetectionProvider
                    ]

                    try await session.run(providers)

                    isRunning = true
                    isPlaneDetectionRunning = true
                    beginConsumingPlaneUpdates()

                    print("[RoomSkinning] ARKit session started")
                    print("[RoomSkinning] vertical plane provider active")

                    return
                }
            }

            try await session.run([worldTrackingProvider])
            isRunning = true
            isPlaneDetectionRunning = false
            print("[RoomSkinning] ARKit session started without plane detection")
        } catch {
            isRunning = false
            isPlaneDetectionRunning = false
            print("[RoomSkinning] ARKit session failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        planeUpdateTask?.cancel()
        planeUpdateTask = nil

        knownHorizontalPlaneYsByID.removeAll()

        guard isRunning else { return }
        session.stop()

        isRunning = false
        isPlaneDetectionRunning = false
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
            matrix.columns.2.y,
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

    func resolvedFloorY(
        for pose: PhaseOneSpawnPose,
        fallbackHeadToFloorOffset: Float,
        timeoutSeconds: TimeInterval
    ) async -> Float {
        let fallbackY = pose.headPosition.y + fallbackHeadToFloorOffset

        guard isPlaneDetectionRunning else {
            return fallbackY
        }

        let timeoutNanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
        let start = DispatchTime.now().uptimeNanoseconds

        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if let floorY = bestKnownFloorY(
                headY: pose.headPosition.y,
                fallbackY: fallbackY
            ) {
                return floorY
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        return bestKnownFloorY(
            headY: pose.headPosition.y,
            fallbackY: fallbackY
        ) ?? fallbackY
    }

    private func beginConsumingPlaneUpdates() {
        planeUpdateTask?.cancel()

        planeUpdateTask = Task { [weak self] in
            guard let self else { return }

            for await update in planeDetectionProvider.anchorUpdates {
                if Task.isCancelled { return }

                switch update.event {
                case .added, .updated:
                    if update.anchor.alignment == .horizontal {
                        let transform = update.anchor.originFromAnchorTransform
                        let planeY = transform.columns.3.y
                        knownHorizontalPlaneYsByID[update.anchor.id] = planeY
                    }

                case .removed:
                    knownHorizontalPlaneYsByID.removeValue(forKey: update.anchor.id)
                }

                onPlaneAnchorUpdate?(update)
            }
        }
    }

    private func bestKnownFloorY(
        headY: Float,
        fallbackY: Float
    ) -> Float? {
        let candidates = knownHorizontalPlaneYsByID.values.filter { planeY in
            planeY < headY - 0.45 &&
            planeY > headY - 2.40
        }

        return candidates.min { lhs, rhs in
            abs(lhs - fallbackY) < abs(rhs - fallbackY)
        }
    }
}

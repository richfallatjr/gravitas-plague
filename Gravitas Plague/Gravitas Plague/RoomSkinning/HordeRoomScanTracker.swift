import Combine
import Foundation
import simd

@MainActor
final class HordeRoomScanTracker: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var isComplete = false
    @Published private(set) var progress: Float = 0

    private let binCount = 36
    private var coveredBins: Set<Int> = []
    private var lastYaw: Float?
    private var accumulatedYawTravel: Float = 0

    func begin() {
        isActive = true
        isComplete = false
        progress = 0
        coveredBins.removeAll()
        lastYaw = nil
        accumulatedYawTravel = 0

        print("[HordeRoomScan] 360 scan started")
    }

    func cancel() {
        isActive = false
        isComplete = false
        progress = 0
        coveredBins.removeAll()
        lastYaw = nil
        accumulatedYawTravel = 0

        print("[HordeRoomScan] scan cancelled")
    }

    func markCompleteForReuse() {
        isActive = false
        isComplete = true
        progress = 1
    }

    func updateHeadForward(
        _ forward: SIMD3<Float>
    ) {
        guard isActive,
              !isComplete else {
            return
        }

        let flat = SIMD2<Float>(
            forward.x,
            forward.z
        )

        guard simd_length(flat) > 0.0001 else {
            return
        }

        let yaw = atan2(flat.x, flat.y)
        let normalizedYaw = normalizeAnglePositive(yaw)
        let bin = min(
            binCount - 1,
            max(
                0,
                Int((normalizedYaw / (2 * .pi)) * Float(binCount))
            )
        )

        coveredBins.insert(bin)

        if let lastYaw {
            accumulatedYawTravel += abs(
                shortestAngleDelta(
                    from: lastYaw,
                    to: yaw
                )
            )
        }

        lastYaw = yaw

        let binProgress = Float(coveredBins.count) / Float(binCount)
        let travelProgress = min(
            1,
            accumulatedYawTravel / (2 * .pi)
        )

        progress = min(
            binProgress,
            travelProgress
        )

        if coveredBins.count >= binCount - 2,
           accumulatedYawTravel >= (2 * .pi * 0.92) {
            isComplete = true
            isActive = false
            progress = 1

            print(
                """
                [HordeRoomScan] 360 scan complete
                  coveredBins: \(coveredBins.count)/\(binCount)
                  accumulatedYawTravel: \(accumulatedYawTravel)
                """
            )
        }
    }

    private func normalizeAnglePositive(
        _ angle: Float
    ) -> Float {
        var value = angle
        while value < 0 { value += 2 * .pi }
        while value >= 2 * .pi { value -= 2 * .pi }
        return value
    }

    private func shortestAngleDelta(
        from lhs: Float,
        to rhs: Float
    ) -> Float {
        var delta = rhs - lhs
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta
    }
}

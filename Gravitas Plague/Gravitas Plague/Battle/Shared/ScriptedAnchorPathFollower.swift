import Foundation
import RealityKit
import simd

@MainActor
final class ScriptedAnchorPathFollower {
    struct Segment {
        let fromID: String
        let toID: String
        let fromWorld: SIMD3<Float>
        let toWorld: SIMD3<Float>
    }

    enum UpdateResult {
        case idle
        case moving(segmentIndex: Int)
        case completed
    }

    private weak var controller: JockRetargetTestController?
    private weak var coordinateSpace: Entity?
    private var segments: [Segment] = []
    private var segmentIndex = 0
    private var sampledFloorPosition = SIMD3<Float>.zero
    private var pendingAuthoredTravel: Float = 0
    private var onCompleted: (() -> Void)?
    private var authoritativeWorldOrientation: simd_quatf?
    private var active = false

    func begin(
        controller: JockRetargetTestController,
        segments: [Segment],
        coordinateSpace: Entity? = nil,
        walkClipID: String? = nil,
        authoritativeWorldOrientation: simd_quatf? = nil,
        transitionToWalkClip: Bool = true,
        onCompleted: @escaping () -> Void
    ) throws {
        guard let first = segments.first else {
            onCompleted()
            return
        }
        self.controller = controller
        self.coordinateSpace = coordinateSpace
        self.segments = segments
        self.segmentIndex = 0
        self.sampledFloorPosition = first.fromWorld
        self.pendingAuthoredTravel = 0
        self.onCompleted = onCompleted
        self.authoritativeWorldOrientation = authoritativeWorldOrientation
        self.active = true

        setControllerPosition(controller, floorPosition: first.fromWorld)
        installAuthoritativeOrientation(on: controller)
        if let walkClipID {
            try controller.playScriptedWalkLoop(
                clipID: walkClipID,
                transition: transitionToWalkClip
            ) { [weak self] distance in
                self?.pendingAuthoredTravel += max(0, distance)
            }
        } else {
            try controller.playScriptedWalkLoop { [weak self] distance in
                self?.pendingAuthoredTravel += max(0, distance)
            }
        }
        logSegmentStart(first)
    }

    @discardableResult
    func update(deltaTime: TimeInterval) -> UpdateResult {
        guard active,
              let controller,
              segments.indices.contains(segmentIndex) else {
            return .idle
        }

        var travel = pendingAuthoredTravel
        pendingAuthoredTravel = 0

        while travel > 0.00001, active,
              segments.indices.contains(segmentIndex) {
            let segment = segments[segmentIndex]
            let remaining = segment.toWorld - sampledFloorPosition
            let fullDistance = simd_length(remaining)

            if fullDistance <= 0.002 {
                finishCurrentSegment()
                continue
            }

            let stepDistance = min(fullDistance, travel)
            let direction = remaining / fullDistance
            sampledFloorPosition += direction * stepDistance
            travel -= stepDistance

            setControllerPosition(controller, floorPosition: sampledFloorPosition)
            if authoritativeWorldOrientation != nil {
                installAuthoritativeOrientation(on: controller)
            } else {
                controller.steerScriptedRootTowardWorldDirection(
                    worldDirection(for: direction),
                    deltaTime: Float(deltaTime)
                )
            }

            if stepDistance >= fullDistance - 0.001 {
                sampledFloorPosition = segment.toWorld
                setControllerPosition(controller, floorPosition: sampledFloorPosition)
                installAuthoritativeOrientation(on: controller)
                finishCurrentSegment()
            }
        }

        return active ? .moving(segmentIndex: segmentIndex) : .completed
    }

    func cancel(reason: String) {
        active = false
        pendingAuthoredTravel = 0
        segments.removeAll(keepingCapacity: false)
        onCompleted = nil
        authoritativeWorldOrientation = nil
        controller?.stopScriptedLocomotion(reason: reason)
        controller = nil
        coordinateSpace = nil
    }

    private func installAuthoritativeOrientation(
        on controller: JockRetargetTestController
    ) {
        guard let authoritativeWorldOrientation else { return }
        controller.rootEntity.setOrientation(
            authoritativeWorldOrientation,
            relativeTo: nil
        )
    }

    private func setControllerPosition(
        _ controller: JockRetargetTestController,
        floorPosition: SIMD3<Float>
    ) {
        var rootPosition = floorPosition
        rootPosition.y = controller.rootYForFloorY(floorPosition.y)
        controller.rootEntity.setPosition(
            rootPosition,
            relativeTo: coordinateSpace
        )
    }

    private func worldDirection(
        for coordinateSpaceDirection: SIMD3<Float>
    ) -> SIMD3<Float> {
        guard let coordinateSpace else {
            return coordinateSpaceDirection
        }
        let transform = coordinateSpace.transformMatrix(relativeTo: nil)
        let world = transform * SIMD4<Float>(
            coordinateSpaceDirection.x,
            coordinateSpaceDirection.y,
            coordinateSpaceDirection.z,
            0
        )
        return PhaseOneMath.normalizedOrFallback(
            SIMD3<Float>(world.x, world.y, world.z),
            fallback: coordinateSpaceDirection
        )
    }

    private func finishCurrentSegment() {
        guard segments.indices.contains(segmentIndex) else { return }
        let finished = segments[segmentIndex]
        print("""
        [Battle01] path segment completed
          from: \(finished.fromID)
          to: \(finished.toID)
        """)

        segmentIndex += 1
        guard segments.indices.contains(segmentIndex) else {
            active = false
            controller?.stopScriptedLocomotion(reason: "pathCompleted")
            let completion = onCompleted
            onCompleted = nil
            completion?()
            return
        }
        logSegmentStart(segments[segmentIndex])
    }

    private func logSegmentStart(_ segment: Segment) {
        print("""
        [Battle01] path segment started
          from: \(segment.fromID)
          to: \(segment.toID)
          distanceMeters: \(simd_distance(segment.fromWorld, segment.toWorld))
          full3DPath: true
        """)
    }
}

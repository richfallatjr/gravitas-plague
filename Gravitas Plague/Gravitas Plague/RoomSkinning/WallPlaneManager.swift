import ARKit
import Combine
import Foundation
import RealityKit
import simd

@MainActor
final class WallPlaneManager: ObservableObject {
    @Published private(set) var wallCandidates: [UUID: WallCandidate] = [:]

    private var lastKnownViewerPosition = SIMD3<Float>(0, 1.5, 0)

    func updateViewerPositionForWallSelection(
        _ position: SIMD3<Float>
    ) {
        lastKnownViewerPosition = position
    }

    func beginScanning() {
        print("[RoomSkinning] wall plane manager scanning")
    }

    func stop() {
        wallCandidates.removeAll()
        print("[RoomSkinning] vertical plane detection stopped")
    }

    func handlePlaneAnchorUpdate(
        _ update: AnchorUpdate<PlaneAnchor>
    ) {
        let anchor = update.anchor

        guard anchor.alignment == .vertical else {
            return
        }

        switch update.event {
        case .added, .updated:
            guard let wall = makeWallCandidate(from: anchor) else {
                return
            }

            wallCandidates[wall.id] = wall

            print(
                """
                [RoomSkinning] wall candidate found id=\(wall.id)
                  anchorID: \(wall.anchorID)
                  size: \(String(format: "%.2f", wall.width)) x \(String(format: "%.2f", wall.height))
                  stability: \(String(format: "%.2f", wall.stabilityScore))
                """
            )

        case .removed:
            let removed = wallCandidates.first {
                $0.value.anchorID == anchor.id
            }

            if let removed {
                wallCandidates.removeValue(forKey: removed.key)

                print(
                    """
                    [RoomSkinning] wall candidate removed
                      id: \(removed.key)
                      anchorID: \(anchor.id)
                    """
                )
            }
        }
    }

    private func makeWallCandidate(
        from anchor: PlaneAnchor
    ) -> WallCandidate? {
        let worldFromAnchor = anchor.originFromAnchorTransform
        let anchorFromExtent = anchor.geometry.extent.anchorFromExtentTransform
        let worldFromExtent = worldFromAnchor * anchorFromExtent

        let width = max(
            Float(anchor.geometry.extent.width),
            0.01
        )

        let height = max(
            Float(anchor.geometry.extent.height),
            0.01
        )

        guard width >= 0.55,
              height >= 0.75 else {
            return nil
        }

        let basis = deriveWallBasisFromExtentTransform(
            worldFromExtent: worldFromExtent,
            width: width,
            height: height,
            viewerPosition: lastKnownViewerPosition
        )

        guard basis.width >= 0.55,
              basis.height >= 0.75 else {
            return nil
        }

        let old = wallCandidates.values.first {
            $0.anchorID == anchor.id
        }

        let stability: Float
        if let old {
            stability = min(
                1.0,
                old.stabilityScore + 0.08
            )
        } else {
            stability = 0.15
        }

        let candidate = WallCandidate(
            id: old?.id ?? UUID(),
            anchorID: anchor.id,
            worldTransform: worldFromExtent,
            center: basis.center,
            normal: basis.normal,
            up: basis.up,
            right: basis.right,
            width: basis.width,
            height: basis.height,
            stabilityScore: stability,
            lastUpdated: Date()
        )

        print(
            """
            [RoomSkinning] wall basis from plane extent
              candidateID: \(candidate.id)
              anchorID: \(anchor.id)
              center: \(candidate.center)
              right: \(candidate.right)
              up: \(candidate.up)
              normal: \(candidate.normal)
              width: \(candidate.width)
              height: \(candidate.height)
              source: plane_extent_not_head
            """
        )

        return candidate
    }

    private func deriveWallBasisFromExtentTransform(
        worldFromExtent: simd_float4x4,
        width: Float,
        height: Float,
        viewerPosition: SIMD3<Float>
    ) -> WallBasis {
        let center = SIMD3<Float>(
            worldFromExtent.columns.3.x,
            worldFromExtent.columns.3.y,
            worldFromExtent.columns.3.z
        )

        let axis0 = normalizeSafe(
            SIMD3<Float>(
                worldFromExtent.columns.0.x,
                worldFromExtent.columns.0.y,
                worldFromExtent.columns.0.z
            ),
            fallback: SIMD3<Float>(1, 0, 0)
        )

        let axis1 = normalizeSafe(
            SIMD3<Float>(
                worldFromExtent.columns.1.x,
                worldFromExtent.columns.1.y,
                worldFromExtent.columns.1.z
            ),
            fallback: SIMD3<Float>(0, 1, 0)
        )

        let axis2 = normalizeSafe(
            SIMD3<Float>(
                worldFromExtent.columns.2.x,
                worldFromExtent.columns.2.y,
                worldFromExtent.columns.2.z
            ),
            fallback: SIMD3<Float>(0, 0, 1)
        )

        let gravityUp = SIMD3<Float>(0, 1, 0)
        let axes = [axis0, axis1, axis2]

        let upIndex = axes.indices.max {
            abs(simd_dot(axes[$0], gravityUp)) < abs(simd_dot(axes[$1], gravityUp))
        } ?? 1

        var up = axes[upIndex]
        if simd_dot(up, gravityUp) < 0 {
            up = -up
        }

        let remaining = axes.indices.filter { $0 != upIndex }
        let toViewer = normalizeSafe(
            viewerPosition - center,
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let normalIndex = remaining.max {
            abs(simd_dot(axes[$0], toViewer)) < abs(simd_dot(axes[$1], toViewer))
        } ?? remaining[0]

        var normal = axes[normalIndex]
        if simd_dot(normal, toViewer) < 0 {
            normal = -normal
        }

        var right = normalizeSafe(
            simd_cross(up, normal),
            fallback: SIMD3<Float>(1, 0, 0)
        )

        normal = normalizeSafe(
            simd_cross(right, up),
            fallback: normal
        )

        if simd_dot(normal, toViewer) < 0 {
            normal = -normal
            right = -right
        }

        print(
            """
            [RoomSkinning] derived wall basis
              upIndex: \(upIndex)
              normalIndex: \(normalIndex)
              upDotGravity: \(simd_dot(up, gravityUp))
              normalDotToViewer: \(simd_dot(normal, toViewer))
              right: \(right)
              up: \(up)
              normal: \(normal)
            """
        )

        return WallBasis(
            center: center,
            right: right,
            up: up,
            normal: normal,
            width: width,
            height: height
        )
    }

    func bestWallCandidate(
        relativeToPlayer playerPosition: SIMD3<Float>,
        playerForward: SIMD3<Float>
    ) -> WallCandidate? {
        let candidates = wallCandidates.values.filter {
            $0.isLargeEnoughForDefaultDoor && $0.stabilityScore >= 0.35
        }

        guard !candidates.isEmpty else {
            return nil
        }

        let scored = candidates.map { wall -> (WallCandidate, Float) in
            let toWall = normalizeSafe(
                wall.center - playerPosition,
                fallback: SIMD3<Float>(0, 0, -1)
            )

            let facesPlayer = max(
                0,
                simd_dot(wall.normal, -toWall)
            )

            let inFront = max(
                0,
                simd_dot(playerForward, toWall)
            )

            let distance = simd_length(wall.center - playerPosition)
            let distanceScore = max(
                0,
                1.0 - abs(distance - 2.0) / 4.0
            )

            let areaScore = min(
                1.0,
                (wall.width * wall.height) / 4.0
            )

            let score =
                facesPlayer * 2.0 +
                inFront * 1.25 +
                distanceScore * 0.75 +
                areaScore +
                wall.stabilityScore

            return (wall, score)
        }

        let best = scored.max { $0.1 < $1.1 }?.0

        if let best {
            print(
                """
                [RoomSkinning] best wall selected id=\(best.id)
                  size: \(String(format: "%.2f", best.width)) x \(String(format: "%.2f", best.height))
                  stability: \(String(format: "%.2f", best.stabilityScore))
                """
            )
        }

        return best
    }

    func projectRayToWall(
        ray: RoomSkinningRay,
        wallID: UUID
    ) -> SIMD3<Float>? {
        guard let wall = wallCandidates[wallID] else {
            return nil
        }

        let denom = simd_dot(ray.direction, wall.normal)

        guard abs(denom) > 0.0001 else {
            return nil
        }

        let t = simd_dot(wall.center - ray.origin, wall.normal) / denom

        guard t > 0 else {
            return nil
        }

        return ray.origin + ray.direction * t
    }

    func convertWorldPointToWallLocal(
        point: SIMD3<Float>,
        wallID: UUID
    ) -> SIMD2<Float>? {
        guard let wall = wallCandidates[wallID] else {
            return nil
        }

        let delta = point - wall.center

        return SIMD2<Float>(
            simd_dot(delta, wall.right),
            simd_dot(delta, wall.up)
        )
    }

    func projectWorldPointToWall(
        _ point: SIMD3<Float>,
        wallID: UUID
    ) -> SIMD3<Float>? {
        guard let wall = wallCandidates[wallID] else {
            return nil
        }

        let distance = simd_dot(
            point - wall.center,
            wall.normal
        )

        return point - wall.normal * distance
    }

    func convertWallLocalToWorldTransform(
        placement: DoorPlacement
    ) -> simd_float4x4? {
        guard let wall = wallCandidates[placement.wallID] else {
            return nil
        }

        let clamped = clampPlacement(
            placement,
            on: wall
        )

        let position =
            wall.center +
            wall.right * clamped.localX +
            wall.up * clamped.localY +
            wall.normal * clamped.depthOffset

        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4<Float>(wall.right.x, wall.right.y, wall.right.z, 0)
        matrix.columns.1 = SIMD4<Float>(wall.up.x, wall.up.y, wall.up.z, 0)
        matrix.columns.2 = SIMD4<Float>(wall.normal.x, wall.normal.y, wall.normal.z, 0)
        matrix.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)

        print(
            """
            [PortalDoor] wall-local transform rebuilt
              wallID: \(clamped.wallID)
              localX: \(clamped.localX)
              localY: \(clamped.localY)
              depthOffset: \(clamped.depthOffset)
              right: \(wall.right)
              up: \(wall.up)
              normal: \(wall.normal)
              position: \(position)
              transformSource: wall_basis_not_head
            """
        )

        return matrix
    }

    func clampPlacement(
        _ placement: DoorPlacement,
        on wall: WallCandidate
    ) -> DoorPlacement {
        var p = placement

        let overhang: Float = 0.075

        let maxX = max(
            0,
            wall.width * 0.5 - placement.width * 0.5 + overhang
        )

        let maxY = max(
            0,
            wall.height * 0.5 - placement.height * 0.5 + overhang
        )

        p.localX = min(max(p.localX, -maxX), maxX)
        p.localY = min(max(p.localY, -maxY), maxY)
        p.depthOffset = max(0.005, min(0.02, p.depthOffset))

        return p
    }
}

private func normalizeSafe(
    _ v: SIMD3<Float>,
    fallback: SIMD3<Float>
) -> SIMD3<Float> {
    let length = simd_length(v)
    guard length > 0.00001 else {
        return fallback
    }
    return v / length
}

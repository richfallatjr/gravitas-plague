import ARKit
import Combine
import Foundation
import RealityKit
import simd

enum FloorLockRequirement {
    case optional
    case required
}

@MainActor
final class WallPlaneManager: ObservableObject {
    @Published private(set) var wallCandidates: [UUID: WallCandidate] = [:]
    @Published private(set) var floorCandidates: [UUID: FloorCandidate] = [:]

    private var lastKnownViewerPosition = SIMD3<Float>(0, 1.55, 0)

    func updateViewerPositionForWallSelection(
        _ position: SIMD3<Float>
    ) {
        updateViewerPoseForPlaneFiltering(
            position: position
        )
    }

    func updateViewerPoseForPlaneFiltering(
        position: SIMD3<Float>
    ) {
        lastKnownViewerPosition = position
    }

    func beginScanning() {
        print("[RoomSkinning] wall plane manager scanning")
    }

    func stop() {
        wallCandidates.removeAll()
        floorCandidates.removeAll()
        print("[RoomSkinning] plane detection stopped")
    }

    func handlePlaneAnchorUpdate(
        _ update: AnchorUpdate<PlaneAnchor>
    ) {
        let anchor = update.anchor

        switch update.event {
        case .added, .updated:
            switch anchor.alignment {
            case .vertical:
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

            case .horizontal:
                guard let floor = makeFloorCandidate(from: anchor) else {
                    return
                }

                floorCandidates[floor.id] = floor

                print(
                    """
                    [RoomSkinning] floor candidate found id=\(floor.id)
                      anchorID: \(floor.anchorID)
                      worldY: \(String(format: "%.3f", floor.worldY))
                      size: \(String(format: "%.2f", floor.width)) x \(String(format: "%.2f", floor.depth))
                      stability: \(String(format: "%.2f", floor.stabilityScore))
                    """
                )

            default:
                break
            }

        case .removed:
            if let removed = wallCandidates.first(where: {
                $0.value.anchorID == anchor.id
            }) {
                wallCandidates.removeValue(forKey: removed.key)

                print(
                    """
                    [RoomSkinning] wall candidate removed
                      id: \(removed.key)
                      anchorID: \(anchor.id)
                    """
                )
            }

            if let removed = floorCandidates.first(where: {
                $0.value.anchorID == anchor.id
            }) {
                floorCandidates.removeValue(forKey: removed.key)

                print(
                    """
                    [RoomSkinning] floor candidate removed
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

    private func makeFloorCandidate(
        from anchor: PlaneAnchor
    ) -> FloorCandidate? {
        let worldFromAnchor = anchor.originFromAnchorTransform
        let anchorFromExtent = anchor.geometry.extent.anchorFromExtentTransform
        let worldFromExtent = worldFromAnchor * anchorFromExtent

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

        let normalIndex = axes.indices.max {
            abs(simd_dot(axes[$0], gravityUp)) < abs(simd_dot(axes[$1], gravityUp))
        } ?? 1

        var normal = axes[normalIndex]
        if simd_dot(normal, gravityUp) < 0 {
            normal = -normal
        }

        let semantic = classifyHorizontalPlane(
            center: center,
            normal: normal
        )

        guard semantic == .floor else {
            print(
                """
                [RoomSkinning] rejected non-floor horizontal plane
                  semantic: \(semantic.rawValue)
                  centerY: \(center.y)
                  viewerY: \(lastKnownViewerPosition.y)
                """
            )
            return nil
        }

        let remaining = axes.indices.filter { $0 != normalIndex }
        let right = normalizeSafe(
            axes[remaining.first ?? 0],
            fallback: SIMD3<Float>(1, 0, 0)
        )

        let forward = normalizeSafe(
            simd_cross(right, normal),
            fallback: SIMD3<Float>(0, 0, -1)
        )

        let width = max(
            Float(anchor.geometry.extent.width),
            0.01
        )

        let depth = max(
            Float(anchor.geometry.extent.height),
            0.01
        )

        guard width >= 0.75,
              depth >= 0.75 else {
            return nil
        }

        let old = floorCandidates.values.first {
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

        let floor = FloorCandidate(
            id: old?.id ?? UUID(),
            anchorID: anchor.id,
            worldTransform: worldFromExtent,
            center: center,
            normal: normal,
            right: right,
            forward: forward,
            width: width,
            depth: depth,
            semantic: semantic,
            stabilityScore: stability,
            lastUpdated: Date()
        )

        print(
            """
            [RoomSkinning] usable floor candidate
              id: \(floor.id)
              anchorID: \(floor.anchorID)
              worldY: \(floor.worldY)
              viewerY: \(lastKnownViewerPosition.y)
              belowViewer: \(lastKnownViewerPosition.y - floor.worldY)
              size: \(floor.width) x \(floor.depth)
              area: \(floor.area)
              semantic: \(floor.semantic.rawValue)
            """
        )

        return floor
    }

    private func classifyHorizontalPlane(
        center: SIMD3<Float>,
        normal: SIMD3<Float>
    ) -> HorizontalPlaneSemantic {
        let upDot = simd_dot(
            normalizeSafe(
                normal,
                fallback: SIMD3<Float>(0, 1, 0)
            ),
            SIMD3<Float>(0, 1, 0)
        )

        guard upDot > 0.75 else {
            print(
                """
                [RoomSkinning] horizontal plane rejected
                  reason: normal_not_up
                  centerY: \(center.y)
                  upDot: \(upDot)
                """
            )
            return .unknown
        }

        let viewerY = lastKnownViewerPosition.y
        let belowViewer = viewerY - center.y

        if belowViewer >= 1.0 && belowViewer <= 2.4 {
            return .floor
        }

        if center.y > viewerY - 0.25 {
            print(
                """
                [RoomSkinning] horizontal plane classified ceiling
                  centerY: \(center.y)
                  viewerY: \(viewerY)
                  belowViewer: \(belowViewer)
                """
            )
            return .ceiling
        }

        print(
            """
            [RoomSkinning] horizontal plane classified highSurface
              centerY: \(center.y)
              viewerY: \(viewerY)
              belowViewer: \(belowViewer)
            """
        )

        return .highSurface
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

    func bestFloorCandidate(
        near wall: WallCandidate? = nil
    ) -> FloorCandidate? {
        let viewerY = lastKnownViewerPosition.y

        let candidates = floorCandidates.values.filter { floor in
            guard floor.isUsableFloor else {
                return false
            }

            guard floor.worldY < viewerY - 0.85 else {
                print(
                    """
                    [PortalDoor] rejected floor candidate above viewer threshold
                      floorY: \(floor.worldY)
                      viewerY: \(viewerY)
                      semantic: \(floor.semantic.rawValue)
                    """
                )
                return false
            }

            if let wall {
                guard floor.worldY < wall.center.y - 0.35 else {
                    print(
                        """
                        [PortalDoor] rejected floor candidate above wall center
                          floorY: \(floor.worldY)
                          wallCenterY: \(wall.center.y)
                          wallID: \(wall.id)
                        """
                    )
                    return false
                }
            }

            return true
        }

        guard !candidates.isEmpty else {
            print(
                """
                [PortalDoor] no usable floor candidates
                  totalHorizontalFloorsTracked: \(floorCandidates.count)
                  viewerY: \(viewerY)
                  wallID: \(wall?.id.uuidString ?? "nil")
                """
            )
            return nil
        }

        let sorted = candidates.sorted { lhs, rhs in
            if let wall {
                let lhsDistance = simd_length(lhs.center - wall.center)
                let rhsDistance = simd_length(rhs.center - wall.center)

                if abs(lhsDistance - rhsDistance) > 0.3 {
                    return lhsDistance < rhsDistance
                }
            }

            if abs(lhs.area - rhs.area) > 0.5 {
                return lhs.area > rhs.area
            }

            if abs(lhs.stabilityScore - rhs.stabilityScore) > 0.1 {
                return lhs.stabilityScore > rhs.stabilityScore
            }

            return lhs.worldY < rhs.worldY
        }

        let chosen = sorted[0]

        print(
            """
            [PortalDoor] best floor candidate selected
              floorID: \(chosen.id)
              floorY: \(chosen.worldY)
              viewerY: \(viewerY)
              wallID: \(wall?.id.uuidString ?? "nil")
              semantic: \(chosen.semantic.rawValue)
              area: \(chosen.area)
              stability: \(chosen.stabilityScore)
            """
        )

        return chosen
    }

    func floorLocalY(
        for wall: WallCandidate,
        floor: FloorCandidate,
        doorHeight: Float,
        bottomClearance: Float
    ) -> Float? {
        let upY = wall.up.y

        guard abs(upY) > 0.05 else {
            return nil
        }

        return ((floor.worldY + bottomClearance) - wall.center.y) / upY
            + doorHeight * 0.5
    }

    func resolveFloorLockedPlacement(
        _ placement: DoorPlacement,
        requirement: FloorLockRequirement = .optional
    ) -> DoorPlacement? {
        guard let wall = wallCandidates[placement.wallID] else {
            return nil
        }

        var resolved = placement

        if resolved.floorLocked {
            let floor =
                resolved.floorAnchorID.flatMap { floorID in
                    floorCandidates.values.first {
                        $0.id == floorID || $0.anchorID == floorID
                    }
                }
                ?? bestFloorCandidate(near: wall)

            guard let floor else {
                switch requirement {
                case .optional:
                    resolved.localY = -wall.height * 0.5
                        + resolved.height * 0.5
                        + resolved.bottomClearance

                    print(
                        """
                        [PortalDoor] floor lock optional fallback to wall lower extent
                          wallID: \(resolved.wallID)
                          localY: \(resolved.localY)
                          reason: no verified floor
                        """
                    )

                    return clampPlacement(
                        resolved,
                        on: wall
                    )

                case .required:
                    print(
                        """
                        [PortalDoor] ERROR required floor lock failed
                          wallID: \(resolved.wallID)
                          reason: no verified floor
                          action: do_not_place_horde_portal
                        """
                    )
                    return nil
                }
            }

            guard let localY = floorLocalY(
                for: wall,
                floor: floor,
                doorHeight: resolved.height,
                bottomClearance: resolved.bottomClearance
            ) else {
                print(
                    """
                    [PortalDoor] ERROR could not solve floor localY
                      wallID: \(resolved.wallID)
                      floorID: \(floor.id)
                    """
                )
                return nil
            }

            resolved.localY = localY
            resolved.floorAnchorID = floor.id
            resolved.floorWorldY = floor.worldY

            print(
                """
                [PortalDoor] floor lock resolved
                  wallID: \(resolved.wallID)
                  floorID: \(floor.id)
                  floorY: \(floor.worldY)
                  localY: \(resolved.localY)
                  requirement: \(requirement)
                """
            )
        }

        return clampPlacement(
            resolved,
            on: wall
        )
    }

    func resolveFloorLockedPlacementOrFallback(
        _ placement: DoorPlacement
    ) -> DoorPlacement {
        guard let resolved = resolveFloorLockedPlacement(
            placement,
            requirement: .optional
        ) else {
            guard let wall = wallCandidates[placement.wallID] else {
                return placement
            }

            var fallback = placement
            if fallback.floorLocked {
                fallback.localY = -wall.height * 0.5
                    + fallback.height * 0.5
                    + fallback.bottomClearance
            }

            return clampPlacement(
                fallback,
                on: wall
            )
        }

        return resolved
    }

    func convertWallLocalToWorldTransform(
        placement: DoorPlacement
    ) -> simd_float4x4? {
        guard let wall = wallCandidates[placement.wallID] else {
            return nil
        }

        let resolved = resolveFloorLockedPlacementOrFallback(placement)

        let position =
            wall.center +
            wall.right * resolved.localX +
            wall.up * resolved.localY +
            wall.normal * resolved.depthOffset

        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4<Float>(wall.right.x, wall.right.y, wall.right.z, 0)
        matrix.columns.1 = SIMD4<Float>(wall.up.x, wall.up.y, wall.up.z, 0)
        matrix.columns.2 = SIMD4<Float>(wall.normal.x, wall.normal.y, wall.normal.z, 0)
        matrix.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)

        let bottomWorld =
            wall.center +
            wall.right * resolved.localX +
            wall.up * (resolved.localY - resolved.height * 0.5)
        let floorWorldYDescription = resolved.floorWorldY.map { value in
            "\(value)"
        } ?? "nil"

        print(
            """
            [PortalDoor] wall-local floor-aware transform rebuilt
              wallID: \(resolved.wallID)
              floorLocked: \(resolved.floorLocked)
              localX: \(resolved.localX)
              localY: \(resolved.localY)
              depthOffset: \(resolved.depthOffset)
              right: \(wall.right)
              up: \(wall.up)
              normal: \(wall.normal)
              position: \(position)
              bottomWorld: \(bottomWorld)
              floorWorldY: \(floorWorldYDescription)
              transformSource: wall_basis_plus_floor
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

        p.localX = min(max(p.localX, -maxX), maxX)

        if !p.floorLocked {
            let maxY = max(
                0,
                wall.height * 0.5 - placement.height * 0.5 + overhang
            )

            p.localY = min(max(p.localY, -maxY), maxY)
        }

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

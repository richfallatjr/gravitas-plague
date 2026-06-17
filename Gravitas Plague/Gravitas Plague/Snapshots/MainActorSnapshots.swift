import Foundation
import simd

struct FrameClockSnapshot: Sendable {
    let frameIndex: Int
    let time: TimeInterval
    let deltaTime: Float
}

struct PlayerPoseSnapshot: Sendable {
    let position: SIMD3<Float>
    let forward: SIMD3<Float>
    let yawRadians: Float
}

enum EnemyBrainStateValue: String, Sendable {
    case inactive
    case idleStopped
    case waitingToFollow
    case following
    case closeRangeReady
    case attacking
    case hitReaction
    case dead
}

struct EnemyBodySnapshot: Sendable, Identifiable {
    let id: UUID
    let characterID: String
    let spawnIndex: Int
    let isAlive: Bool
    let isAttacking: Bool
    let position: SIMD3<Float>
    let yawRadians: Float
    let centerWorld: SIMD3<Float>
    let rightXZ: SIMD2<Float>
    let forwardXZ: SIMD2<Float>
    let halfWidth: Float
    let halfDepth: Float
    let minY: Float
    let maxY: Float
    let distanceToUserXZ: Float
}

struct EnemyBrainSnapshot: Sendable, Identifiable {
    let id: UUID
    let characterID: String
    let spawnIndex: Int
    let state: EnemyBrainStateValue
    let position: SIMD3<Float>
    let yawRadians: Float
    let health: Int
    let isDead: Bool
    let isHitReacting: Bool
    let isAttacking: Bool
    let attackAnchorUserPosition: SIMD3<Float>?
    let closeRangeDelayRemaining: TimeInterval?
    let crowdSteerAngleRadians: Float
    let attackEnabled: Bool
    let attackProximityMeters: Float
    let resumeFollowDistanceMeters: Float
    let aggressiveDelayMinSeconds: TimeInterval
    let aggressiveDelayMaxSeconds: TimeInterval
}

struct PortalRuntimeSnapshot: Sendable, Identifiable {
    let id: UUID
    let waveCreated: Int
    let wallID: UUID
    let worldCenter: SIMD3<Float>
    let bearingFromPlayerRadians: Float
    let resolvedFloorWorldY: Float?
    let entranceCount: Int
}

func normalizeSnapshotAxis2(
    _ value: SIMD2<Float>,
    fallback: SIMD2<Float>
) -> SIMD2<Float> {
    let length = simd_length(value)

    guard length > 0.00001 else {
        return fallback
    }

    return value / length
}

#if DEBUG
@MainActor
enum MainActorSnapshotDebugAssertions {
    private static var checkedTypes = Set<String>()

    private static let forbiddenTypeMarkers = [
        "RealityKit.Entity",
        "RealityKit.ModelEntity",
        "RealityKit.Scene",
        "ARKit.ARKitSession",
        "ARKit.WorldTrackingProvider",
        "ARKit.HandTrackingProvider",
        "ARKit.PlaneDetectionProvider",
        "ObservableObject",
        "Published",
        "JockRetargetTestController",
        "PlagueImmersiveCoordinator",
        "HordePortalManager",
        "WallPlaneManager",
        "RoomSkinningCoordinator",
        "GravitasDemoAudioController",
        "() ->"
    ]

    static func assertValueOnlySnapshot<T>(
        _ snapshot: T,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let rootType = String(reflecting: T.self)

        guard !checkedTypes.contains(rootType) else {
            return
        }

        checkedTypes.insert(rootType)

        inspect(
            snapshot,
            path: rootType,
            depth: 0,
            file: file,
            line: line
        )
    }

    private static func inspect(
        _ value: Any,
        path: String,
        depth: Int,
        file: StaticString,
        line: UInt
    ) {
        guard depth <= 8 else {
            return
        }

        let typeName = String(reflecting: Swift.type(of: value))

        for marker in forbiddenTypeMarkers where typeName.contains(marker) {
            assertionFailure(
                """
                [Snapshot] forbidden stored type detected
                  path: \(path)
                  type: \(typeName)
                  marker: \(marker)
                """,
                file: file,
                line: line
            )
        }

        let mirror = Mirror(reflecting: value)

        guard !mirror.children.isEmpty else {
            return
        }

        for child in mirror.children {
            let childPath = "\(path).\(child.label ?? "_")"

            inspect(
                child.value,
                path: childPath,
                depth: depth + 1,
                file: file,
                line: line
            )
        }
    }
}
#endif

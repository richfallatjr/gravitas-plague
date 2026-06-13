import Foundation
import RealityKit
import simd

enum RoomSkinningState: String, Codable {
    case idle
    case requestingPermissions
    case scanning
    case wallCandidateAvailable
    case doorPreviewVisible
    case adjustingDoor
    case doorConfirmed
    case failed
}

enum PortalDoorState: String, Codable {
    case notCreated
    case preview
    case active
    case adjusting
    case confirmed
    case disabled
}

struct WallBasis: Equatable {
    var center: SIMD3<Float>
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    var normal: SIMD3<Float>

    var width: Float
    var height: Float

    var worldFromDoorLocal: simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(right.x, right.y, right.z, 0)
        m.columns.1 = SIMD4<Float>(up.x, up.y, up.z, 0)
        m.columns.2 = SIMD4<Float>(normal.x, normal.y, normal.z, 0)
        m.columns.3 = SIMD4<Float>(center.x, center.y, center.z, 1)
        return m
    }
}

enum PortalHDRIAtmosphere: String, Codable, CaseIterable, Identifiable, Equatable {
    case overcast
    case night

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overcast:
            return "Overcast"

        case .night:
            return "Night"
        }
    }

    var exrResourceName: String {
        switch self {
        case .overcast:
            return "forest-overcast-01"

        case .night:
            return "forest-night-01"
        }
    }

    var exrExtension: String {
        "exr"
    }

    var next: PortalHDRIAtmosphere {
        switch self {
        case .overcast:
            return .night

        case .night:
            return .overcast
        }
    }

    var iblIntensityExponent: Float {
        switch self {
        case .overcast:
            return 0.85

        case .night:
            return 0.38
        }
    }

    var visibleExposure: Float {
        switch self {
        case .overcast:
            return 1.0

        case .night:
            return 0.75
        }
    }
}

struct WallCandidate: Identifiable {
    let id: UUID
    let anchorID: UUID

    var worldTransform: simd_float4x4

    var center: SIMD3<Float>
    var normal: SIMD3<Float>
    var up: SIMD3<Float>
    var right: SIMD3<Float>

    var width: Float
    var height: Float

    var stabilityScore: Float
    var lastUpdated: Date

    var basis: WallBasis {
        WallBasis(
            center: center,
            right: right,
            up: up,
            normal: normal,
            width: width,
            height: height
        )
    }

    var isLargeEnoughForDefaultDoor: Bool {
        width >= 1.0 && height >= 1.8
    }
}

enum HorizontalPlaneSemantic: String, Codable {
    case floor
    case ceiling
    case highSurface
    case unknown
}

struct FloorCandidate: Identifiable {
    let id: UUID
    let anchorID: UUID

    var worldTransform: simd_float4x4

    var center: SIMD3<Float>
    var normal: SIMD3<Float>
    var right: SIMD3<Float>
    var forward: SIMD3<Float>

    var width: Float
    var depth: Float
    var semantic: HorizontalPlaneSemantic

    var worldY: Float {
        center.y
    }

    var area: Float {
        width * depth
    }

    var stabilityScore: Float
    var lastUpdated: Date

    var isUsableFloor: Bool {
        semantic == .floor &&
            stabilityScore >= 0.25 &&
            area >= 1.2
    }
}

struct PortalDoorHandleComponent: Component, Codable {
    var doorID: String
}

struct DoorPlacement: Codable, Equatable {
    var wallID: UUID

    /// X slides horizontally along wallRight.
    var localX: Float

    /// Door center in wall-local Y. If floorLocked is true,
    /// this is resolved from the floor every transform.
    var localY: Float

    /// Tiny offset along wall normal to avoid z-fighting.
    var depthOffset: Float

    var width: Float
    var height: Float

    var confirmed: Bool
    var contentProviderID: String

    /// If true, bottom of portal stays on detected floor.
    var floorLocked: Bool

    /// Floor candidate or anchor ID used when available.
    var floorAnchorID: UUID?

    /// Last known floor world Y for session stability.
    var floorWorldY: Float?

    /// Small lift above floor to avoid z-fighting.
    var bottomClearance: Float

    static func defaultForWall(
        _ wall: WallCandidate
    ) -> DoorPlacement {
        DoorPlacement(
            wallID: wall.id,
            localX: 0,
            localY: -wall.height * 0.5 + 1.0,
            depthOffset: 0.012,
            width: 0.92,
            height: 2.0,
            confirmed: false,
            contentProviderID: HDRIDomePortalContentProvider.providerID,
            floorLocked: true,
            floorAnchorID: nil,
            floorWorldY: nil,
            bottomClearance: 0.015
        )
    }
}

struct PortalContentContext: Codable, Equatable {
    var doorWidth: Float
    var doorHeight: Float

    /// In portal-world local space. Door opening is centered at 0,
    /// so floor is normally -doorHeight / 2.
    var floorY: Float

    var groundDiscEnabled: Bool
    var groundDiscRadius: Float
    var groundDiscCenterZ: Float

    static func forDoor(
        width: Float,
        height: Float
    ) -> PortalContentContext {
        PortalContentContext(
            doorWidth: width,
            doorHeight: height,
            floorY: -height * 0.5,
            groundDiscEnabled: true,
            groundDiscRadius: max(2.8, width * 3.0),
            groundDiscCenterZ: -2.25
        )
    }
}

struct RoomSkinningRay {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
}

enum PortalHDRIAssetValidator {
    static func validate() {
        for atmosphere in PortalHDRIAtmosphere.allCases {
            if let url = Bundle.main.url(
                forResource: atmosphere.exrResourceName,
                withExtension: atmosphere.exrExtension
            ) {
                print(
                    """
                    [PortalHDRI] found EXR
                      atmosphere: \(atmosphere.rawValue)
                      file: \(atmosphere.exrResourceName).exr
                      url: \(url.path)
                    """
                )
            } else {
                print(
                    """
                    [PortalHDRI] ERROR missing EXR
                      atmosphere: \(atmosphere.rawValue)
                      file: \(atmosphere.exrResourceName).exr
                    """
                )
            }
        }
    }
}

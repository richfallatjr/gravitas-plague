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

    var isLargeEnoughForDefaultDoor: Bool {
        width >= 1.0 && height >= 1.8
    }
}

struct DoorPlacement: Codable, Equatable {
    var wallID: UUID

    /// X slides horizontally along wallRight.
    var localX: Float

    /// Y slides vertically along wallUp.
    var localY: Float

    /// Fixed offset away from wall normal to avoid z-fighting.
    var depthOffset: Float

    var width: Float
    var height: Float

    var confirmed: Bool
    var contentProviderID: String

    static func defaultForWall(
        _ wall: WallCandidate
    ) -> DoorPlacement {
        let doorWidth: Float = 0.92
        let doorHeight: Float = 2.0

        let localY: Float

        if wall.height > doorHeight {
            localY = max(
                -wall.height * 0.5 + doorHeight * 0.5,
                -0.2
            )
        } else {
            localY = 0
        }

        return DoorPlacement(
            wallID: wall.id,
            localX: 0,
            localY: localY,
            depthOffset: 0.012,
            width: doorWidth,
            height: doorHeight,
            confirmed: false,
            contentProviderID: HDRIDomePortalContentProvider.providerID
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

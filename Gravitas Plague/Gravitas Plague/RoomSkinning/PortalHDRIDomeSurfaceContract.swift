import Foundation

enum PortalHDRIDomeMeshWinding:
    String,
    Sendable,
    Equatable,
    Hashable,
    Codable
{
    case outward
    case inward
}

enum PortalHDRIDomeSurfaceContract:
    String,
    Sendable,
    Equatable,
    Hashable,
    Codable
{
    case storyInteriorOnly
    case legacyPreserveCurrentBehavior

    var meshWinding: PortalHDRIDomeMeshWinding {
        .outward
    }

    var expectedFaceCullingLabel: String {
        switch self {
        case .storyInteriorOnly:
            return "front"

        case .legacyPreserveCurrentBehavior:
            return "back_with_negative_x_scale"
        }
    }
}

struct PortalHDRIPanoramaOrientation:
    Sendable,
    Equatable
{
    enum HorizontalUVMode:
        String,
        Sendable,
        Equatable
    {
        case native
        case legacyNegativeXEquivalent
    }

    let baseYawRadians: Float
    let horizontalUVMode: HorizontalUVMode

    static let story = PortalHDRIPanoramaOrientation(
        baseYawRadians: .pi / 2.0,
        horizontalUVMode: .native
    )

    static let legacy = PortalHDRIPanoramaOrientation(
        baseYawRadians: .pi / 2.0,
        horizontalUVMode: .legacyNegativeXEquivalent
    )
}

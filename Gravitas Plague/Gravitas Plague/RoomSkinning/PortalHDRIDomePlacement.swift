import Foundation

struct PortalHDRIDomePlacement:
    Sendable,
    Equatable,
    Hashable,
    Codable
{
    let radiusMeters: Float
    let centerOffsetZ: Float

    static let storyOpening = PortalHDRIDomePlacement(
        radiusMeters: 12.0,
        centerOffsetZ: -9.0
    )

    static let centeredLegacy = PortalHDRIDomePlacement(
        radiusMeters: PortalHDRIDomePlacementTuning.radiusMeters,
        centerOffsetZ: 0.0
    )

    var nearestShellDistanceMeters: Float {
        radiusMeters - abs(centerOffsetZ)
    }

    func validate(usage: String) throws {
        guard radiusMeters.isFinite,
              radiusMeters > 0 else {
            throw PortalHDRIDomeError.invalidPlacement(
                "\(usage) radius must be finite and positive."
            )
        }

        guard centerOffsetZ.isFinite else {
            throw PortalHDRIDomeError.invalidPlacement(
                "\(usage) center offset must be finite."
            )
        }

        guard abs(centerOffsetZ) < radiusMeters else {
            throw PortalHDRIDomeError.invalidPlacement(
                "\(usage) portal origin must remain inside the sphere."
            )
        }
    }
}

enum PortalHDRIDomePlacementTuning {
    static let radiusMeters: Float = 12.0
    static let storyOpeningRadiusMeters = PortalHDRIDomePlacement.storyOpening.radiusMeters
    static let storyOpeningCenterOffsetZ = PortalHDRIDomePlacement.storyOpening.centerOffsetZ
    static let storyOpeningCameraClearanceMeters =
        PortalHDRIDomePlacement.storyOpening.nearestShellDistanceMeters
}

enum PortalHDRIDomeError:
    LocalizedError,
    Sendable,
    Equatable
{
    case invalidPlacement(String)
    case unknownProvider(String)
    case invalidStoryRuntime(String)
    case missingModelComponent
    case missingUnlitMaterial

    var errorDescription: String? {
        switch self {
        case .invalidPlacement(let message),
             .invalidStoryRuntime(let message):
            return message

        case .unknownProvider(let providerID):
            return "Unknown portal content provider: \(providerID)."

        case .missingModelComponent:
            return "The panorama dome has no ModelComponent."

        case .missingUnlitMaterial:
            return "The panorama dome is not using the expected UnlitMaterial."
        }
    }
}

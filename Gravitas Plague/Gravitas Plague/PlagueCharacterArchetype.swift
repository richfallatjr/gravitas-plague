import Foundation
import RealityKit

enum PlagueCharacterArchetype: String, CaseIterable, Identifiable, Codable {
    case dad
    case neighbor
    case spouse
    // Future:
    // case convict
    // case grandma

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .dad:
            return "Dad"
        case .neighbor:
            return "Neighbor"
        case .spouse:
            return "Spouse"
        }
    }

    nonisolated var usdzResourceName: String {
        switch self {
        case .dad:
            return "dad_biped"
        case .neighbor:
            return "neighbor_biped"
        case .spouse:
            return "spouse_biped"
        }
    }

    nonisolated var usdzFileName: String {
        "\(usdzResourceName).usdz"
    }

    nonisolated var poseApplicationPolicy: JockPoseApplicationPolicy {
        switch self {
        case .dad:
            return .authorAbsoluteLocal
        case .neighbor, .spouse:
            return .sourceRestDeltaToTargetRest
        }
    }
}

enum CharacterAssetRegistry {
    static let requiredHordeAssets: [PlagueCharacterArchetype] = [
        .dad,
        .neighbor,
        .spouse
    ]

    static func url(
        for archetype: PlagueCharacterArchetype
    ) -> URL? {
        Bundle.main.url(
            forResource: archetype.usdzResourceName,
            withExtension: "usdz"
        )
    }

    static func validateRequiredCharacterAssets() {
        for archetype in requiredHordeAssets {
            if let url = url(for: archetype) {
                print(
                    """
                    [CharacterAssetRegistry] found character asset
                      archetype: \(archetype.rawValue)
                      file: \(archetype.usdzFileName)
                      url: \(url.path)
                    """
                )
            } else {
                print(
                    """
                    [CharacterAssetRegistry] ERROR missing required character asset
                      archetype: \(archetype.rawValue)
                      file: \(archetype.usdzFileName)
                    """
                )
            }
        }
    }
}

enum HordeCharacterWaveLineup {
    static let deterministicRoster: [PlagueCharacterArchetype] = [
        .dad,
        .neighbor,
        .spouse
    ]

    static func archetypeForSpawnIndex(
        _ index: Int
    ) -> PlagueCharacterArchetype {
        deterministicRoster[index % deterministicRoster.count]
    }

    static func lineup(
        wave: Int
    ) -> [PlagueCharacterArchetype] {
        guard wave > 0 else {
            return []
        }

        return (0..<wave).map { index in
            archetypeForSpawnIndex(index)
        }
    }
}

enum CharacterRigValidator {
    static func validate(
        archetype: PlagueCharacterArchetype,
        root: Entity
    ) {
        var jointLikeNames: [String] = []

        root.visitRecursively { entity in
            let name = entity.name

            if name.contains("Hips") ||
                name.contains("Spine") ||
                name.contains("Arm") ||
                name.contains("Leg") ||
                name.contains("Foot") ||
                name.contains("Hand") ||
                name.contains("Head") {
                jointLikeNames.append(name)
            }
        }

        print(
            """
            [CharacterRigValidator] character rig scan
              archetype: \(archetype.rawValue)
              jointLikeNames: \(jointLikeNames.count)
              sample: \(jointLikeNames.prefix(20).joined(separator: ", "))
            """
        )
    }
}

extension Entity {
    func visitRecursively(
        _ block: (Entity) -> Void
    ) {
        block(self)

        for child in children {
            child.visitRecursively(block)
        }
    }
}

import Foundation
import RealityKit

enum PlagueCharacterArchetype: String, CaseIterable, Identifiable, Codable {
    case dad
    case spouse
    case biker
    case grandma
    case neighbor
    case robot
    // Future:
    // case convict

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .dad:
            return "Dad"
        case .spouse:
            return "Spouse"
        case .biker:
            return "Biker"
        case .grandma:
            return "Grandma"
        case .neighbor:
            return "Neighbor"
        case .robot:
            return "Robot"
        }
    }

    nonisolated var usdzResourceName: String {
        switch self {
        case .dad:
            return "dad_biped"
        case .spouse:
            return "spouse_biped"
        case .biker:
            return "biker_biped"
        case .grandma:
            return "grandma_biped"
        case .neighbor:
            return "neighbor_biped"
        case .robot:
            return "robot_biped"
        }
    }

    nonisolated var usdzFileName: String {
        "\(usdzResourceName).usdz"
    }

    nonisolated var poseApplicationPolicy: JockPoseApplicationPolicy {
        switch self {
        case .dad:
            return .authorAbsoluteLocal
        case .spouse, .biker, .grandma, .neighbor, .robot:
            return .sourceRestDeltaToTargetRest
        }
    }
}

extension PlagueCharacterArchetype {
    var hordeHitsToKillRange: ClosedRange<Int> {
        switch self {
        case .neighbor:
            return 6...10

        case .robot:
            return 9...15

        case .dad, .spouse, .biker, .grandma:
            return 3...5
        }
    }

    func randomHordeHitsToKill() -> Int {
        Int.random(
            in: hordeHitsToKillRange
        )
    }
}

enum CharacterAssetRegistry {
    static let requiredHordeAssets: [PlagueCharacterArchetype] = [
        .dad,
        .spouse,
        .biker,
        .grandma,
        .neighbor,
        .robot
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
        .spouse,
        .biker,
        .grandma,
        .neighbor,
        .robot
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
    func debugTreeSummary(
        limit: Int
    ) -> String {
        var lines: [String] = []
        var didTruncate = false

        func visit(
            _ entity: Entity,
            depth: Int
        ) {
            guard lines.count < limit else {
                didTruncate = true
                return
            }

            let indentation = String(
                repeating: "  ",
                count: depth
            )

            let displayName = entity.name.isEmpty
                ? "(unnamed)"
                : entity.name

            lines.append(
                "\(indentation)- \(displayName) [\(type(of: entity))]"
            )

            for child in entity.children {
                visit(
                    child,
                    depth: depth + 1
                )
            }
        }

        visit(
            self,
            depth: 0
        )

        if didTruncate {
            lines.append("...")
        }

        return lines.joined(separator: "\n")
    }

    func visitRecursively(
        _ block: (Entity) -> Void
    ) {
        block(self)

        for child in children {
            child.visitRecursively(block)
        }
    }
}

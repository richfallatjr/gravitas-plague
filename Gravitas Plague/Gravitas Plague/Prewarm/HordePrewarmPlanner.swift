import Foundation

struct HordeWavePrewarmRequirement: Sendable {
    let characterID: String
    let cloneCount: Int
    let clipIDs: Set<String>
}

struct HordePrewarmPlan: Sendable {
    let reason: String
    let requirements: [HordeWavePrewarmRequirement]

    var allClipIDs: Set<String> {
        requirements.reduce(into: Set<String>()) {
            $0.formUnion($1.clipIDs)
        }
    }
}

enum HordePrewarmPlanner {
    static func planForInitialHordeStart(
        enabledCharacters: [CharacterAttributes],
        preloadAllEnabledCharacters: Bool
    ) -> HordePrewarmPlan {
        let selected = preloadAllEnabledCharacters
            ? enabledCharacters
            : Array(enabledCharacters.prefix(2))

        let requirements = selected.map {
            HordeWavePrewarmRequirement(
                characterID: $0.characterID,
                cloneCount: 1,
                clipIDs: $0.allReferencedAnimationClipIDs
            )
        }

        return HordePrewarmPlan(
            reason: preloadAllEnabledCharacters
                ? "initial_horde_start_all_enabled"
                : "initial_horde_start_lookahead",
            requirements: requirements
        )
    }

    static func planForWave(
        waveIndex: Int,
        lineup: [PlagueCharacterArchetype],
        attributesByArchetype: [PlagueCharacterArchetype: CharacterAttributes]
    ) -> HordePrewarmPlan {
        var countsByCharacterID: [String: Int] = [:]

        for archetype in lineup {
            guard let attributes = attributesByArchetype[archetype] else {
                continue
            }

            countsByCharacterID[attributes.characterID, default: 0] += 1
        }

        let requirements = countsByCharacterID.compactMap { characterID, count -> HordeWavePrewarmRequirement? in
            guard let attributes = attributesByArchetype.values.first(where: { $0.characterID == characterID }) else {
                return nil
            }

            return HordeWavePrewarmRequirement(
                characterID: characterID,
                cloneCount: count,
                clipIDs: attributes.allReferencedAnimationClipIDs
            )
        }
        .sorted {
            $0.characterID < $1.characterID
        }

        return HordePrewarmPlan(
            reason: "wave_\(waveIndex)",
            requirements: requirements
        )
    }
}

extension CharacterAttributes {
    var allReferencedAnimationClipIDs: Set<String> {
        var clipIDs = Set<String>()

        func insert(
            _ refs: [AnimationClipRef]
        ) {
            for ref in refs {
                clipIDs.insert(ref.clipID)
            }
        }

        insert(animations.idle)
        insert(animations.walk)
        insert(animations.turn.left90)
        insert(animations.turn.right90)
        insert(animations.attack)
        insert(animations.damage)
        insert(animations.death)

        return clipIDs
    }
}


import Foundation
import RealityKit

@MainActor
final class HordePrewarmCoordinator {
    private let characterCache = HordeCharacterPrototypeCache.shared
    private let animationCache = JockAnimationClipPrewarmCache.shared

    private var attributesByCharacterID: [String: CharacterAttributes] = [:]

    func installCharacterAttributes(
        _ attributes: [CharacterAttributes]
    ) {
        attributesByCharacterID = Dictionary(
            uniqueKeysWithValues: attributes.map {
                ($0.characterID, $0)
            }
        )

        print(
            """
            [HordePrewarm] installed character attributes
              characterCount: \(attributes.count)
              characters: \(attributes.map(\.characterID).sorted().joined(separator: ", "))
            """
        )
    }

    func prewarm(
        plan: HordePrewarmPlan
    ) async throws {
        print(
            """
            [HordePrewarm] starting plan
              reason: \(plan.reason)
              requirements: \(plan.requirements.map { "\($0.characterID)x\($0.cloneCount)" }.joined(separator: ", "))
              clipCount: \(plan.allClipIDs.count)
            """
        )

        for requirement in plan.requirements {
            guard let attributes = attributesByCharacterID[requirement.characterID] else {
                throw HordePrewarmError.characterNotReady(
                    characterID: requirement.characterID
                )
            }

            try await characterCache.prewarmPrototype(
                attributes: attributes,
                requestedSpawnCapacity: requirement.cloneCount
            )
        }

        print(
            """
            [HordePrewarm] plan complete
              reason: \(plan.reason)
              noSpawnHitchesExpected: true
            """
        )
    }

    func requireReadyForSpawn(
        characterID: String
    ) throws {
        let status = characterCache.status(
            characterID: characterID,
            requiredCloneCount: 1
        )

        guard status.state == .ready else {
            print(
                """
                [HordePrewarm] ERROR spawn requested before character ready
                  characterID: \(characterID)
                  state: \(status.state.rawValue)
                  sourceReady: false
                  fallback: false
                """
            )

            throw HordePrewarmError.characterNotReady(
                characterID: characterID
            )
        }
    }

    func checkoutPreparedAssetsForSpawn(
        characterID: String
    ) async throws -> HordePrewarmedCharacterSpawnAssets {
        try requireReadyForSpawn(
            characterID: characterID
        )

        let entity = try characterCache.makeSpawnClone(
            characterID: characterID
        )

        return HordePrewarmedCharacterSpawnAssets(
            characterEntity: entity
        )
    }

    func returnCharacterEntityAfterCleanup(
        _ entity: Entity,
        characterID: String,
        reason: String = "cleanup",
        desiredCleanCount: Int = 1
    ) {
        _ = desiredCleanCount

        characterCache.discardSpawnClone(
            entity,
            characterID: characterID,
            reason: reason
        )
    }

    func discardCharacterEntityAfterFailedSpawn(
        _ entity: Entity,
        characterID: String,
        reason: String
    ) {
        characterCache.discardSpawnClone(
            entity,
            characterID: characterID,
            reason: reason
        )
    }

    func releaseAll() {
        characterCache.releaseAll()

        Task {
            await animationCache.releaseAll()
        }
    }
}

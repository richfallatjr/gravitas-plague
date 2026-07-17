import Foundation
import RealityKit

@MainActor
final class BattleCorpsePresentationController {
    private let storyRoot: Entity
    private var corpsesByEnemyID: [UUID: Entity] = [:]

    init(storyRoot: Entity) {
        self.storyRoot = storyRoot
    }

    func installStaticCorpse(
        resourcePath: String,
        sourceRoot: Entity?,
        enemyIdentity: BattleEnemyRuntimeIdentity
    ) async throws -> Bool {
        guard let sourceRoot else { return false }
        let sourceTransform = sourceRoot.transformMatrix(relativeTo: nil)
        let resourceURL = try TuringResourceLoader.resourceURL(
            resourcePath: resourcePath
        )
        let corpse = try await Entity(contentsOf: resourceURL)
        corpse.name = "BattleCorpse_\(enemyIdentity.enemyID.uuidString)"
        stripInteractiveComponents(from: corpse)
        storyRoot.addChild(corpse)
        corpse.setTransformMatrix(sourceTransform, relativeTo: nil)
        corpsesByEnemyID[enemyIdentity.enemyID] = corpse
        return true
    }

    func remove(enemyID: UUID, reason: String) {
        corpsesByEnemyID.removeValue(forKey: enemyID)?.removeFromParent()
        print("[BattleRuntimeCleanup] static corpse removed enemyID=\(enemyID) reason=\(reason)")
    }

    func removeAll(reason: String) {
        for corpse in corpsesByEnemyID.values {
            corpse.removeFromParent()
        }
        let count = corpsesByEnemyID.count
        corpsesByEnemyID.removeAll(keepingCapacity: false)
        print("[BattleRuntimeCleanup] static corpses removed count=\(count) reason=\(reason)")
    }

    private func stripInteractiveComponents(from entity: Entity) {
        entity.components.remove(InputTargetComponent.self)
        entity.components.remove(CollisionComponent.self)
        entity.components.remove(SpatialAudioComponent.self)
        for child in entity.children {
            stripInteractiveComponents(from: child)
        }
    }
}

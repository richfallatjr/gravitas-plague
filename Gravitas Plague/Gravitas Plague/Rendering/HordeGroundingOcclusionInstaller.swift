import Foundation
import RealityKit

@MainActor
enum HordeGroundingOcclusionInstaller {
    /// Flip this to true to re-enable Apple's GroundingShadowComponent path.
    /// Kept centralized so perf testing can disable the whole feature without
    /// changing room, portal, or enemy spawn code.
    private static let groundingShadowsEnabled = false

    private static var disabledLogKeys = Set<String>()

    /// Installs RealityKit's built-in grounding receiver on the actual skinned
    /// room/floor geometry. This does not add lights, fake geometry, or custom
    /// occlusion receiver materials.
    @discardableResult
    static func installRoomReceivers(
        on roomGeometryRoot: Entity,
        reason: String
    ) -> Int {
        guard groundingShadowsEnabled else {
            logDisabledOnce(
                key: "room_receivers_\(reason)",
                """
                [HordeGroundingOcclusion] disabled room receiver install
                  reason: \(reason)
                  root: \(roomGeometryRoot.name)
                  groundingShadowsEnabled: false
                """
            )

            return 0
        }

        var receiverCount = 0

        visitRecursively(roomGeometryRoot) { entity in
            guard entity.components[ModelComponent.self] != nil else {
                return
            }

            entity.components.set(
                GroundingShadowComponent(
                    castsShadow: false,
                    receivesShadow: true
                )
            )

            receiverCount += 1
        }

        print(
            """
            [HordeGroundingOcclusion] room receivers installed
              reason: \(reason)
              root: \(roomGeometryRoot.name)
              receiverModelCount: \(receiverCount)
              appleComponent: GroundingShadowComponent
              castsShadow: false
              receivesShadow: true
              usesLights: false
              usesOcclusionReceiverMaterial: false
              generatedReceiverPlane: false
            """
        )

        if receiverCount == 0 {
            print(
                """
                [HordeGroundingOcclusion] WARNING no ModelComponents found on room receiver root
                  root: \(roomGeometryRoot.name)
                  expected: skinned room/floor geometry
                """
            )
        }

        return receiverCount
    }

    /// Installs RealityKit's built-in grounding caster on the real zombie body.
    /// The component stays on the zombie after death, so corpse grounding remains
    /// until the visible body is removed.
    @discardableResult
    static func installZombieCasters(
        on zombieRoot: Entity,
        enemyID: UUID?,
        characterID: String,
        reason: String
    ) -> Int {
        guard groundingShadowsEnabled else {
            logDisabledOnce(
                key: "zombie_casters_\(reason)",
                """
                [HordeGroundingOcclusion] disabled zombie caster install
                  reason: \(reason)
                  characterID: \(characterID)
                  groundingShadowsEnabled: false
                """
            )

            return 0
        }

        var casterCount = 0

        visitRecursively(zombieRoot) { entity in
            guard entity.components[ModelComponent.self] != nil else {
                return
            }

            entity.components.set(
                GroundingShadowComponent(
                    castsShadow: true,
                    receivesShadow: false
                )
            )

            casterCount += 1
        }

        print(
            """
            [HordeGroundingOcclusion] zombie casters installed
              reason: \(reason)
              enemyID: \(enemyID?.uuidString ?? "nil")
              characterID: \(characterID)
              root: \(zombieRoot.name)
              casterModelCount: \(casterCount)
              appleComponent: GroundingShadowComponent
              castsShadow: true
              receivesShadow: false
              realGameplayBody: true
              portalMirror: false
              usesLights: false
              generatedReceiverPlane: false
            """
        )

        if casterCount == 0 {
            print(
                """
                [HordeGroundingOcclusion] WARNING no ModelComponents found on zombie root
                  enemyID: \(enemyID?.uuidString ?? "nil")
                  characterID: \(characterID)
                  root: \(zombieRoot.name)
                """
            )
        }

        return casterCount
    }

    /// Portal render mirrors clone the source character hierarchy. Strip this
    /// component from mirror clones so only the real room-side gameplay body
    /// participates in grounding occlusion.
    static func removeGroundingComponents(
        from root: Entity,
        reason: String
    ) {
        var removedCount = 0

        visitRecursively(root) { entity in
            if entity.components[GroundingShadowComponent.self] != nil {
                entity.components.remove(GroundingShadowComponent.self)
                removedCount += 1
            }
        }

        print(
            """
            [HordeGroundingOcclusion] grounding components removed
              reason: \(reason)
              root: \(root.name)
              removedCount: \(removedCount)
            """
        )
    }

    private static func visitRecursively(
        _ entity: Entity,
        _ body: (Entity) -> Void
    ) {
        body(entity)

        for child in entity.children {
            visitRecursively(child, body)
        }
    }

    private static func logDisabledOnce(
        key: String,
        _ message: String
    ) {
        guard !disabledLogKeys.contains(key) else {
            return
        }

        disabledLogKeys.insert(key)
        print(message)
    }
}

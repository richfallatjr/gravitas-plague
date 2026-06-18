import Foundation
import RealityKit

@MainActor
final class HordeCharacterPrototypeCache {
    static let shared = HordeCharacterPrototypeCache()

    struct Record {
        let characterID: String
        let attributes: CharacterAttributes
        let prototype: Entity

        var state: HordePrewarmState
        var errorDescription: String?
    }

    private var recordsByCharacterID: [String: Record] = [:]
    private var loadTasksByCharacterID: [String: Task<Void, Error>] = [:]

    private init() {}

    func status(
        characterID: String,
        requiredCloneCount: Int = 0
    ) -> HordeCharacterPrewarmStatus {
        if let record = recordsByCharacterID[characterID] {
            return HordeCharacterPrewarmStatus(
                characterID: characterID,
                state: record.state,
                sourceAssetName: record.attributes.asset.usdz,
                readyCloneCount: record.state == .ready ? 1 : 0,
                requiredCloneCount: requiredCloneCount,
                errorDescription: record.errorDescription
            )
        }

        return HordeCharacterPrewarmStatus(
            characterID: characterID,
            state: .notRequested,
            sourceAssetName: "",
            readyCloneCount: 0,
            requiredCloneCount: requiredCloneCount,
            errorDescription: nil
        )
    }

    func prewarmPrototype(
        attributes: CharacterAttributes,
        requestedSpawnCapacity: Int
    ) async throws {
        let characterID = attributes.characterID

        if let existing = recordsByCharacterID[characterID],
           existing.state == .ready {
            print(
                """
                [HordePrewarm] prototype already loaded
                  characterID: \(characterID)
                  requestedSpawnCapacity: \(requestedSpawnCapacity)
                  reload: false
                """
            )

            return
        }

        if let task = loadTasksByCharacterID[characterID] {
            try await task.value
            return
        }

        let task = Task { @MainActor in
            try await self.loadPrototype(
                attributes: attributes
            )
        }

        loadTasksByCharacterID[characterID] = task

        do {
            try await task.value
        } catch {
            loadTasksByCharacterID[characterID] = nil
            throw error
        }

        loadTasksByCharacterID[characterID] = nil
    }

    private func loadPrototype(
        attributes: CharacterAttributes
    ) async throws {
        let characterID = attributes.characterID

        guard let url = CharacterAssetRegistry.url(
            attributes: attributes
        ) else {
            let message = "Missing character USDZ \(attributes.asset.usdz)"

            recordsByCharacterID[characterID] = Record(
                characterID: characterID,
                attributes: attributes,
                prototype: Entity(),
                state: .failed,
                errorDescription: message
            )

            print(
                """
                [HordePrewarm] ERROR missing character asset
                  characterID: \(characterID)
                  file: \(attributes.asset.usdz)
                  fallback: false
                """
            )

            throw HordePrewarmError.missingCharacterAsset(
                characterID: characterID,
                file: attributes.asset.usdz
            )
        }

        let prototype = try await Entity(
            contentsOf: url
        )
        prototype.name = "HORDE_PROTOTYPE_\(characterID)"
        prototype.removeFromParent()
        prototype.isEnabled = false

        recordsByCharacterID[characterID] = Record(
            characterID: characterID,
            attributes: attributes,
            prototype: prototype,
            state: .ready,
            errorDescription: nil
        )

        print(
            """
            [HordePrewarm] prototype loaded from USDZ once
              characterID: \(characterID)
              file: \(attributes.asset.usdz)
              cached: true
              parented: false
              extraRestPoseFix: false
              hiddenRotationFix: false
            """
        )
    }

    func makeSpawnClone(
        characterID: String
    ) throws -> Entity {
        guard let record = recordsByCharacterID[characterID],
              record.state == .ready else {
            throw HordePrewarmError.characterNotReady(
                characterID: characterID
            )
        }

        let clone = record.prototype.clone(
            recursive: true
        )
        clone.name = "HORDE_SPAWN_CLONE_\(characterID)_\(UUID().uuidString.prefix(6))"
        clone.removeFromParent()
        clone.isEnabled = true

        print(
            """
            [HordePrewarm] spawn clone created from prototype
              characterID: \(characterID)
              diskLoad: false
              oldFreshLoadEquivalent: true
              dirtyCloneReuse: false
            """
        )

        return clone
    }

    func discardSpawnClone(
        _ clone: Entity,
        characterID: String,
        reason: String
    ) {
        clone.stopAllAnimations()
        clone.removeFromParent()
        clone.isEnabled = false

        print(
            """
            [HordePrewarm] spawn clone discarded
              characterID: \(characterID)
              reason: \(reason)
              returnedToPool: false
              prototypeStillCached: true
            """
        )
    }

    func releaseAll() {
        for task in loadTasksByCharacterID.values {
            task.cancel()
        }

        for (_, record) in recordsByCharacterID {
            record.prototype.removeFromParent()
        }

        recordsByCharacterID.removeAll()
        loadTasksByCharacterID.removeAll()

        print("[HordePrewarm] released prototype cache")
    }
}

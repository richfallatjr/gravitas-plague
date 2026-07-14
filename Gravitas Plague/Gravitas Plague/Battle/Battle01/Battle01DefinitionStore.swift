import Foundation

struct Battle01DefinitionStore: Sendable {
    enum StoreError: LocalizedError {
        case invalidSchema(Int)
        case invalidContract(String)

        var errorDescription: String? {
            switch self {
            case .invalidSchema(let value):
                return "Battle01 schemaVersion must be 1, got \(value)."
            case .invalidContract(let reason):
                return "Invalid Battle01 definition: \(reason)"
            }
        }
    }

    func load() throws -> Battle01Definition {
        let definition = try TuringResourceLoader.decodeResource(
            Battle01Definition.self,
            resourcePath: "Turing/Battles/Battle01/battle01.json"
        )
        guard definition.schemaVersion == 1 else {
            throw StoreError.invalidSchema(definition.schemaVersion)
        }
        guard definition.trigger.scriptPointID == "prologue.scriptPoint03",
              definition.enemy.anchorIDs == ["zombie_a1", "zombie_a2", "zombie_a3"],
              definition.enemy.turnCount == 2,
              definition.music.loop == false else {
            throw StoreError.invalidContract("authored trigger, anchors, turns, or music loop changed")
        }
        return definition
    }

    func soundtrackURL(for definition: Battle01Definition) throws -> URL {
        try TuringResourceLoader.resourceURL(
            resourcePath: "Turing/Audio/battle01/\(definition.music.file)"
        )
    }
}

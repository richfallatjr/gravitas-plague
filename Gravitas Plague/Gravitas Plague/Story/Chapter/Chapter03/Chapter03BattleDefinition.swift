import Foundation

struct Chapter03BattleDefinition: Codable, Sendable, Equatable {
    struct Enemy: Codable, Sendable, Equatable {
        let storyEnemyID: String
        let characterID: String
        let sourceAsset: String
        let idleDurationSeconds: Double
        let turnCount: Int
        let turnDegreesPerCompletion: Float
        let storyAcceptedHitCapacityMultiplier: Int
        let acceptedCapacityNumerator: Int
        let acceptedCapacityDenominator: Int
    }

    struct Music: Codable, Sendable, Equatable {
        let lane: String
        let resourcePath: String
        let gainDB: Float
        let loop: Bool
    }

    struct RichCue: Codable, Sendable, Equatable {
        let cueID: String
        let prerecordingID: String
        let gainDB: Float
    }

    let schemaVersion: Int
    let battleID: String
    let enemy: Enemy
    let playerConfirmedHitsToKill: Int
    let music: [Music]
    let richCues: [RichCue]
    let surrenderMusicCrossfadeSeconds: Double
    let postSurrenderPrerecordingBeatSeconds: Double
    let fadeToBlackSeconds: Double
}

struct Chapter03BattleDefinitionStore: Sendable {
    enum Kind: Sendable {
        case biker
        case mike

        var resourcePath: String {
            switch self {
            case .biker:
                return "Turing/Battles/Chapter03BikerBattle/chapter03_biker_battle.json"
            case .mike:
                return "Turing/Battles/Chapter03MikeBattle/chapter03_mike_battle.json"
            }
        }
    }

    func load(_ kind: Kind) throws -> Chapter03BattleDefinition {
        let value = try TuringResourceLoader.decodeResource(
            Chapter03BattleDefinition.self,
            resourcePath: kind.resourcePath
        )
        guard value.schemaVersion == 1,
              value.playerConfirmedHitsToKill == 10,
              value.music.allSatisfy({ $0.gainDB == -7 && !$0.loop }),
              value.enemy.turnCount == 2,
              value.enemy.turnDegreesPerCompletion == 90 else {
            throw Chapter03Error.definitionInvalid(
                "Chapter 3 battle schema, player budget, -7 dB music, or portal turn contract changed."
            )
        }
        switch kind {
        case .biker:
            guard value.battleID == "chapter03.bikerBattle.001",
                  value.enemy.characterID == "biker",
                  value.music.map(\.lane) == ["biker"] else {
                throw Chapter03Error.definitionInvalid("Invalid Biker battle definition.")
            }
        case .mike:
            guard value.battleID == "chapter03.mikeBattle.001",
                  value.enemy.characterID == "neighbor",
                  value.enemy.acceptedCapacityNumerator == 4,
                  value.enemy.acceptedCapacityDenominator == 3,
                  value.music.map(\.lane) == ["bigMikePhaseOne", "bigMikePhaseTwo"] else {
                throw Chapter03Error.definitionInvalid("Invalid Mike battle definition.")
            }
        }
        for music in value.music {
            _ = try TuringResourceLoader.resourceURL(resourcePath: music.resourcePath)
        }
        return value
    }
}

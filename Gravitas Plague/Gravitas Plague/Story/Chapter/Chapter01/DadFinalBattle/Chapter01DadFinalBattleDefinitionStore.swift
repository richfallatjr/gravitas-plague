import Foundation

struct Chapter01DadFinalBattleDefinitionStore: Sendable {
    enum StoreError: LocalizedError {
        case invalidSchema(Int)
        case invalidContract(String)

        var errorDescription: String? {
            switch self {
            case .invalidSchema(let value):
                return "Dad final battle schemaVersion must be 1, got \(value)."
            case .invalidContract(let message):
                return "Invalid Dad final battle definition: \(message)"
            }
        }
    }

    func load() throws -> Chapter01DadFinalBattleDefinition {
        let definition = try TuringResourceLoader.decodeResource(
            Chapter01DadFinalBattleDefinition.self,
            resourcePath:
                "Turing/Battles/Chapter01DadFinalBattle/chapter01_dad_final_battle.json"
        )
        guard definition.schemaVersion == 1 else {
            throw StoreError.invalidSchema(definition.schemaVersion)
        }
        let timedCue = try definition.musicTimedRichCue
        let remainingCue = try definition.oneDamageRemainingRichCue
        guard definition.battleID == "chapter01.dadFinalBattle.001",
              definition.trigger.checkpoint == "chapter01.preDadFinalBattle.ready",
              definition.trigger.requiresAllPostRobotBranches,
              definition.trigger.terminalScriptPointID ==
                Chapter01PostRobotBranch.hamReceiver.terminalScriptPointID,
              definition.enemy.characterID == "dad",
              definition.enemy.sourceAsset == "dad_biped.usdz",
              definition.enemy.anchorIDs == ["zombie_a1", "zombie_a2", "zombie_a3"],
              definition.enemy.idleClipID == "idle_01",
              definition.enemy.turnClipID == "turn_right_90",
              definition.enemy.turnCount == 2,
              definition.enemy.walkClipID == "unstable_walk_01",
              definition.enemy.incomingPunchPolicy == "storyGrandmaThreeX",
              definition.enemy.storyAcceptedHitCapacityMultiplier == 2,
              definition.enemy.retainCorpseAfterDeath == false,
              definition.door.playerMayOpenDuringPortalApproach,
              definition.door.playerMayCloseDuringBattle == false,
              definition.music.loop == false,
              definition.music.start == "actualInitialIdleAnimationStart",
              definition.music.damageEnableAtMediaTimeSeconds == 60,
              definition.playerDamage.confirmedHitsToKillAfterEnable == 5,
              timedCue.triggerMediaTimeSeconds == 30,
              timedCue.gainDB == -5,
              remainingCue.gainDB == -5,
              definition.richPrerecordedCuePolicy.ordered,
              definition.richPrerecordedCuePolicy.maximumActivePlayers == 1,
              definition.richPrerecordedCuePolicy.blocksCombat == false,
              definition.richPrerecordedCuePolicy.usesWalkieEnvelope == false,
              definition.richPrerecordedCuePolicy.usesGeneratedSpeech == false else {
            throw StoreError.invalidContract("authored trigger, enemy, timing, or cue policy changed")
        }
        _ = try soundtrackURL(for: definition)
        return definition
    }

    func soundtrackURL(
        for definition: Chapter01DadFinalBattleDefinition
    ) throws -> URL {
        try TuringResourceLoader.resourceURL(
            resourcePath: definition.music.resourcePath
        )
    }
}

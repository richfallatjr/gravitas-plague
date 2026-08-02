import Foundation

struct Chapter01DadFinalBattleDefinition: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let battleID: String
    let trigger: Trigger
    let enemy: Enemy
    let door: Door
    let portalHandoff: PortalHandoff
    let music: Music
    let playerDamage: PlayerDamage
    let richPrerecordedCues: [RichPrerecordedCue]
    let richPrerecordedCuePolicy: RichPrerecordedCuePolicy

    struct Trigger: Codable, Sendable, Hashable {
        let checkpoint: String
        let requiresAllPostRobotBranches: Bool
        let terminalScriptPointID: String
    }

    struct Enemy: Codable, Sendable, Hashable {
        let storyEnemyID: String
        let characterID: String
        let sourceAsset: String
        let anchorIDs: [String]
        let idleClipID: String
        let idleDurationSeconds: Double
        let turnClipID: String
        let turnCount: Int
        let turnDegreesPerCompletion: Float
        let walkClipID: String
        let externalMotionDriven: Bool
        let rootMotionEnabledDuringPath: Bool
        let incomingPunchPolicy: String
        let storyAcceptedHitCapacityMultiplier: Int
        let retainCorpseAfterDeath: Bool
        let removalDelayAfterMusicEndSeconds: Double
    }

    struct Door: Codable, Sendable, Hashable {
        let playerMayOpenDuringPortalApproach: Bool
        let playerMayCloseDuringBattle: Bool
        let autoOpenIfClosedAtLastAnchor: Bool
        let waitInIdleAtLastAnchorWhileOpening: Bool
        let lockAtLastAnchorAndDuringCrossing: Bool
        let requireFullyOpenBeforeCrossing: Bool
    }

    struct PortalHandoff: Codable, Sendable, Hashable {
        let reuseHordeRenderMirror: Bool
        let sourceIsAnimationAuthority: Bool
        let sourceIsCombatAuthority: Bool
        let mirrorHasCollision: Bool
        let mirrorHasAudio: Bool
        let mirrorHasDamageAuthority: Bool
        let revealThresholdPortalLocalZMeters: Float
        let exitThresholdPortalLocalZMeters: Float
    }

    struct Music: Codable, Sendable, Hashable {
        let resourcePath: String
        let loop: Bool
        let gainDB: Float
        let start: String
        let damageEnableAtMediaTimeSeconds: Double
        let damageRemainsEnabledAfterNaturalCompletion: Bool
        let fadeOutDurationSeconds: Double
    }

    struct PlayerDamage: Codable, Sendable, Hashable {
        let confirmedHitsToKillAfterEnable: Int
        let preEnableDisposition: String
        let clock: String
    }

    struct RichPrerecordedCue: Codable, Sendable, Hashable {
        let cueID: String
        let prerecordingID: String
        let trigger: String
        let triggerMediaTimeSeconds: Double?
        let outputRoute: String
        let gainDB: Float
    }

    struct RichPrerecordedCuePolicy: Codable, Sendable, Hashable {
        let ordered: Bool
        let maximumActivePlayers: Int
        let blocksCombat: Bool
        let usesWalkieEnvelope: Bool
        let usesGeneratedSpeech: Bool
    }

    var musicTimedRichCue: RichPrerecordedCue {
        get throws {
            guard let cue = richPrerecordedCues.first(where: {
                $0.trigger == "soundtrackMediaTime"
            }) else {
                throw Chapter01DadFinalBattleDefinitionStore.StoreError
                    .invalidContract("missing soundtrack-timed Rich cue")
            }
            return cue
        }
    }

    var oneDamageRemainingRichCue: RichPrerecordedCue {
        get throws {
            guard let cue = richPrerecordedCues.first(where: {
                $0.trigger == "acceptedDamageRemainingEqualsOneNonlethal"
            }) else {
                throw Chapter01DadFinalBattleDefinitionStore.StoreError
                    .invalidContract("missing one-damage-remaining Rich cue")
            }
            return cue
        }
    }
}

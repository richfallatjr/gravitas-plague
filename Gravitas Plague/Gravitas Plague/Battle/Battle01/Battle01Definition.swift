import Foundation

struct Battle01Definition: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let battleID: String
    let trigger: Trigger
    let enemy: Enemy
    let door: Door
    let portalHandoff: PortalHandoff
    let music: Music
    let aftermathMusic: AftermathMusic
    let richPrerecording: RichPrerecording
    let turingInteraction: TuringInteraction
    let completion: Completion

    struct Trigger: Codable, Sendable, Hashable {
        let scriptPointID: String
        let requiresSuccessfulActualPlaybackCompletion: Bool
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
        let reuseExistingFollowSpeed: Bool
        let externalMotionDriven: Bool
        let rootMotionEnabledDuringPath: Bool
        let retainCorpseAfterDeath: Bool
        let corpseRemovalDelaySeconds: Double
    }

    struct Door: Codable, Sendable, Hashable {
        let autoOpenIfClosed: Bool
        let waitAtLastAnchorWhileOpening: Bool
        let lockPlayerInteractionDuringWaitAndCrossing: Bool
        let requireFullyOpenBeforeCrossing: Bool
        let requirePlayerGaze: Bool
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
        let file: String
        let loop: Bool
        let trigger: String
        let stop: String
    }

    struct AftermathMusic: Codable, Sendable, Hashable {
        let file: String
        let loop: Bool
        let trigger: String
        let delayAfterGrandmaDeathMinSeconds: Double
        let delayAfterGrandmaDeathMaxSeconds: Double
        let crossfadeDurationSeconds: Double
        let targetDecibels: Float
        let stop: String
    }

    struct RichPrerecording: Codable, Sendable, Hashable {
        let prerecordingID: String
        let delayAfterMusicPlaybackStartedSeconds: Double
        let outputRoute: String
        let playWalkieOpenSound: Bool
        let playWalkieSendSound: Bool
        let playStatic: Bool
        let generatePromptVoice: Bool
    }

    struct TuringInteraction: Codable, Sendable, Hashable {
        let preserveExistingGate: Bool
        let expectedGateAtStart: String
        let allowBigMikeConversationDuringBattle: Bool
    }

    struct Completion: Codable, Sendable, Hashable {
        let startAnotherScriptPoint: Bool
        let removeCorpse: Bool
        let closeMicrophone: Bool
        let stateAfterMusicAndDeath: String
    }
}

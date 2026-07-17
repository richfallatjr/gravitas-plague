import Foundation

enum BattleEnemyReleaseReason: String, Sendable {
    case neutralized
    case battleCompleted
    case battleCancelled
    case storyTeleport
    case storyReset
    case immersiveShutdown
    case modeSwitch
    case memoryPressure
}

enum BattleEnemyRetentionPolicy: Sendable, Equatable {
    case remove
    case staticCorpse(resourcePath: String)
    case reusablePool
}

enum BattleEnemyRuntimeReleaseError: LocalizedError {
    case invalidRetentionPolicy

    var errorDescription: String? {
        "Reusable pooling cannot be used for final Story battle release."
    }
}

struct BattleEnemyRuntimeIdentity: Hashable, Sendable {
    let battleInstanceID: UUID
    let enemyID: UUID
    let enemyTypeID: String
}

struct BattleEnemyRuntimeReleaseResult: Sendable, Equatable {
    let identity: BattleEnemyRuntimeIdentity
    let heavyRuntimeReleased: Bool
    let visibleRuntimeRemoved: Bool
    let staticCorpseInstalled: Bool
    let releasedPreparedClipCount: Int
    let releasedCollisionCount: Int
    let releasedAudioControllerCount: Int
    let weakControllerReleased: Bool
    let notes: [String]

    init(
        identity: BattleEnemyRuntimeIdentity,
        heavyRuntimeReleased: Bool,
        visibleRuntimeRemoved: Bool,
        staticCorpseInstalled: Bool,
        releasedPreparedClipCount: Int,
        releasedCollisionCount: Int,
        releasedAudioControllerCount: Int,
        weakControllerReleased: Bool = false,
        notes: [String]
    ) {
        self.identity = identity
        self.heavyRuntimeReleased = heavyRuntimeReleased
        self.visibleRuntimeRemoved = visibleRuntimeRemoved
        self.staticCorpseInstalled = staticCorpseInstalled
        self.releasedPreparedClipCount = releasedPreparedClipCount
        self.releasedCollisionCount = releasedCollisionCount
        self.releasedAudioControllerCount = releasedAudioControllerCount
        self.weakControllerReleased = weakControllerReleased
        self.notes = notes
    }

    func recordingControllerRelease(_ released: Bool) -> Self {
        Self(
            identity: identity,
            heavyRuntimeReleased: heavyRuntimeReleased,
            visibleRuntimeRemoved: visibleRuntimeRemoved,
            staticCorpseInstalled: staticCorpseInstalled,
            releasedPreparedClipCount: releasedPreparedClipCount,
            releasedCollisionCount: releasedCollisionCount,
            releasedAudioControllerCount: releasedAudioControllerCount,
            weakControllerReleased: released,
            notes: notes
        )
    }
}

@MainActor
protocol BattleEnemyRuntimeReleasable: AnyObject {
    var battleRuntimeIdentity: BattleEnemyRuntimeIdentity { get }

    func releaseBattleRuntime(
        reason: BattleEnemyReleaseReason,
        retentionPolicy: BattleEnemyRetentionPolicy,
        corpsePresenter: BattleCorpsePresentationController
    ) async throws -> BattleEnemyRuntimeReleaseResult
}

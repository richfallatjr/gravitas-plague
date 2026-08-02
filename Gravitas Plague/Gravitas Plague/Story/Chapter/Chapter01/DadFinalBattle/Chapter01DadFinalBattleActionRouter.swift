import Foundation
import simd

@MainActor
final class Chapter01DadFinalBattleActionRouter:
    Chapter01PreDadFinalBattleReadySink {
    private let episodeFlow: TuringEpisodeFlowController
    private let arbiter: StoryInteractionArbiter
    private let battle: Chapter01DadFinalBattleCoordinator
    private var handledCheckpointRevisions = Set<Int>()
    private var battleStarted = false

    init(
        battle: Chapter01DadFinalBattleCoordinator,
        episodeFlow: TuringEpisodeFlowController = .shared,
        arbiter: StoryInteractionArbiter = .shared
    ) {
        self.battle = battle
        self.episodeFlow = episodeFlow
        self.arbiter = arbiter
    }

    func preDadFinalBattleBecameReady(
        _ event: Chapter01PreDadFinalBattleReadyEvent
    ) async {
        guard event.completedBranches == Set(
            Chapter01PostRobotBranch.allCases
        ),
        handledCheckpointRevisions.insert(event.checkpointRevision).inserted,
        !battleStarted else {
            return
        }

        let battleInstanceID = UUID()
        do {
            let lease = try await episodeFlow
                .transferActiveInteractionToBattle(
                    battleInstanceID: battleInstanceID,
                    reason: "chapter01HamTerminalToDadFinalBattle"
                )
            battleStarted = true
            battle.start(
                chapterRunID: event.chapterRunID,
                battleInstanceID: battleInstanceID,
                interactionLease: lease
            )
        } catch {
            handledCheckpointRevisions.remove(event.checkpointRevision)
            battleStarted = false
            print(
                "[Chapter01DadBattle] ERROR live ownership transfer failed " +
                    "revision=\(event.checkpointRevision) " +
                    "error=\(error.localizedDescription)"
            )
        }
    }

    func startFromContinuation(
        snapshot: Chapter01ProgressSnapshot,
        chapterRunID: UUID,
        transitionLease: StoryInteractionLease
    ) async throws {
        guard snapshot.checkpoint == .preDadFinalBattleReady,
              snapshot.postRobot.allBranchesComplete else {
            throw Chapter01Error.unsupportedContinuationCheckpoint
        }
        guard !battleStarted else { return }

        let battleInstanceID = UUID()
        do {
            let battleLease = try await arbiter
                .transferStoryTransitionToBattle(
                    storyTransitionLease: transitionLease,
                    battleInstanceID: battleInstanceID,
                    reason: "chapter01DadFinalBattleContinuation"
                )
            battleStarted = true
            handledCheckpointRevisions.insert(snapshot.revision)
            battle.start(
                chapterRunID: chapterRunID,
                battleInstanceID: battleInstanceID,
                interactionLease: battleLease
            )
        } catch {
            battleStarted = false
            throw error
        }
    }

    func update(
        deltaTime: TimeInterval,
        playerTargetWorldPosition: SIMD3<Float>?
    ) {
        battle.update(
            deltaTime: deltaTime,
            playerTargetWorldPosition: playerTargetWorldPosition
        )
    }

    func waitUntilRuntimeReleased() async {
        await battle.waitUntilRuntimeReleased()
    }

    func reset(reason: String) async {
        await battle.cancel(reason: reason)
        handledCheckpointRevisions.removeAll(keepingCapacity: false)
        battleStarted = false
        print("[Chapter01DadBattle] action router reset reason=\(reason)")
    }
}

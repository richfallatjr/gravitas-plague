import Foundation

@MainActor
final class Chapter01Coordinator:
    TuringStoryCompletionEventSink,
    Chapter01DadWindowCompletionSink,
    Chapter01RobotEncounterCompletionSink {

    typealias RobotStarter = @MainActor (
        UUID,
        StoryInteractionLease,
        any Chapter01RobotEncounterCompletionSink
    ) async throws -> Void

    typealias RobotCanceller = @MainActor (String) async -> Void

    private let progress: Chapter01ProgressStore
    private let episodeFlow: TuringEpisodeFlowController
    private let arbiter: StoryInteractionArbiter
    private let walkie: TuringStoryWalkieInteractionController
    private let dad: Chapter01DadWindowCoordinator
    private let startRobot: RobotStarter
    private let cancelRobot: RobotCanceller

    private(set) var state: Chapter01State = .idle
    private var chapterRunID: UUID?
    private var storyTransitionLease: StoryInteractionLease?
    private var handledCompletionEventIDs = Set<UUID>()

    init(
        walkie: TuringStoryWalkieInteractionController,
        dad: Chapter01DadWindowCoordinator,
        progress: Chapter01ProgressStore = .shared,
        episodeFlow: TuringEpisodeFlowController = .shared,
        arbiter: StoryInteractionArbiter = .shared,
        startRobot: @escaping RobotStarter,
        cancelRobot: @escaping RobotCanceller
    ) {
        self.walkie = walkie
        self.dad = dad
        self.progress = progress
        self.episodeFlow = episodeFlow
        self.arbiter = arbiter
        self.startRobot = startRobot
        self.cancelRobot = cancelRobot
    }

    func beginAtRoot() async throws {
        guard TuringStoryStageCoordinator.shared.isEstablished else {
            throw Chapter01Error.stageNotEstablished
        }
        await cancel(reason: "beginAtRoot")
        try await dad.validateAvailability()

        let runID = UUID()
        chapterRunID = runID
        handledCompletionEventIDs.removeAll(keepingCapacity: false)
        _ = try await progress.resetForReplay(sourceEventID: runID)
        await episodeFlow.resetEpisode(reason: "chapter01.root")
        walkie.episodeStarted(.chapter01)
        walkie.armPlay(
            action: .startScriptPoint(
                id: "chapter01.walkie.rich.script06",
                trigger: .userPlay
            ),
            reason: "chapter01.root"
        )
        state = .rootReady
        print(
            "[Chapter01] root armed chapterRunID=\(runID.uuidString) scriptPointID=chapter01.walkie.rich.script06 noRescan=true"
        )
    }

    func scriptPointCompleted(
        _ event: TuringScriptPointCompletionEvent
    ) async throws {
        guard handledCompletionEventIDs.insert(event.eventID).inserted else {
            return
        }
        guard let chapterRunID else {
            throw Chapter01Error.missingRun
        }

        switch event.scriptPointID {
        case "chapter01.walkie.rich.script06":
            _ = try await progress.commit(
                .script06Completed,
                sourceEventID: event.eventID
            )
            state = .script07

        case "chapter01.walkie.bigMike.script07":
            _ = try await progress.commit(
                .script07Completed,
                sourceEventID: event.eventID
            )
            _ = try await progress.commit(
                .dadWindowPending,
                sourceEventID: UUID()
            )

            let lease = try await episodeFlow
                .transferActiveInteractionToStoryTransition(
                    transitionID: UUID(),
                    reason: "chapter01Script07Completed"
                )
            storyTransitionLease = lease
            state = .dadWindow
            do {
                try await dad.start(
                    request: Chapter01DadWindowRequest(
                        chapterRunID: chapterRunID,
                        storyTransitionLease: lease,
                        completionSink: self
                    )
                )
            } catch {
                storyTransitionLease = nil
                await arbiter.release(
                    lease,
                    reason: "chapter01DadStartFailed"
                )
                state = .failed(error.localizedDescription)
                throw error
            }

        default:
            throw TuringRuntimeError.invalidConfig(
                "Unexpected Chapter 01 ScriptPoint completion: \(event.scriptPointID)"
            )
        }
    }

    func conversationPlaybackCompleted(
        _ event: TuringConversationPlaybackCompletionEvent
    ) async throws {
        throw Chapter01Error.unexpectedConversationCompletion
    }

    func dadExitWalkStarted(
        _ event: Chapter01DadExitWalkStartedEvent
    ) async throws {
        guard let chapterRunID,
              event.chapterRunID == chapterRunID,
              event.locomotionActuallyStarted,
              let lease = storyTransitionLease,
              lease == event.storyTransitionLease else {
            throw Chapter01Error.staleDadEvent
        }

        _ = try await progress.commit(
            .robotEncounterPending,
            sourceEventID: UUID()
        )
        try await startRobot(chapterRunID, lease, self)
        storyTransitionLease = nil
        state = .robot
        print(
            "[Chapter01] Dad exit locomotion started; Robot encounter accepted chapterRunID=\(chapterRunID.uuidString)"
        )
    }

    func dadRuntimeReleased(
        _ event: Chapter01DadRuntimeReleasedEvent
    ) async {
        guard event.chapterRunID == chapterRunID else { return }
        print(
            "[Chapter01] Dad runtime release acknowledged heavyRuntimeReleased=\(event.releaseReport.heavyRuntimeReleased)"
        )
    }

    func dadWindowFailed(
        _ event: Chapter01DadWindowFailureEvent
    ) async {
        guard event.chapterRunID == chapterRunID else { return }
        state = .failed(event.message)
        print(
            "[Chapter01] ERROR Dad window failed chapterRunID=\(event.chapterRunID.uuidString) message=\(event.message)"
        )
        if let storyTransitionLease {
            self.storyTransitionLease = nil
            await arbiter.release(
                storyTransitionLease,
                reason: "chapter01DadWindowFailed"
            )
        }
    }

    func robotEncounterCompleted(
        _ event: Chapter01RobotEncounterCompletionEvent
    ) async throws {
        guard event.chapterRunID == chapterRunID else {
            throw Chapter01Error.missingRun
        }
        state = .postRobotHolding
        await arbiter.release(
            event.hamTuringLease,
            reason: "chapter01OpeningCompleteHamPointsNotInstalled"
        )
        print(
            "[Chapter01] Robot encounter completed; opening is in post-Robot holding state"
        )
    }

    func robotEncounterFailed(
        _ event: Chapter01RobotEncounterFailureEvent
    ) async {
        guard event.chapterRunID == chapterRunID else { return }
        state = .failed(event.message)
    }

    func update(deltaTime: TimeInterval) {
        dad.update(deltaTime: deltaTime)
    }

    func cancel(reason: String) async {
        await episodeFlow.cancelActiveSequence(reason: reason)
        await dad.cancel(reason: reason)
        await cancelRobot(reason)
        if let storyTransitionLease {
            self.storyTransitionLease = nil
            await arbiter.release(storyTransitionLease, reason: reason)
        }
        if let chapterRunID {
            await Chapter01MusicController.shared.stopAll(
                chapterRunID: chapterRunID,
                reason: reason
            )
        }
        chapterRunID = nil
        handledCompletionEventIDs.removeAll(keepingCapacity: false)
        state = .cancelled
    }
}

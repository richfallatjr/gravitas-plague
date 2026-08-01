import Foundation
import RealityKit

enum Chapter01DadWindowState: Sendable, Equatable {
    case unloaded
    case loading
    case atEntry
    case walkingEntryToCenter
    case turningLeftAtCenter
    case centeredIdle20Seconds
    case turningRightToExit
    case walkingCenterToExit
    case releasing
    case released
    case failed(String)
    case cancelled
}

@MainActor
final class Chapter01DadWindowCoordinator {
    private static let centeredIdleDurationSeconds: TimeInterval = 20

    private let windowBundle: TuringStoryWindowBundleController
    private let heavyRuntimeRegistry: StoryHeavyRuntimeRegistry
    private let chapterMusic: Chapter01MusicController
    private let dadPrerecording: Chapter01DadWindowPrerecordingController
    private let pathFollower = ScriptedAnchorPathFollower()

    private(set) var state: Chapter01DadWindowState = .unloaded
    private var request: Chapter01DadWindowRequest?
    private var runtime: Chapter01DadRuntime?
    private var activeTask: Task<Void, Never>?
    private var pathContinuation: CheckedContinuation<Void, Error>?
    private var turnContinuation: CheckedContinuation<Void, Error>?
    private var activeTurnToken: UUID?
    private var contextAcquired = false
    private var generation: UInt64 = 0

    var hasActiveRuntime: Bool {
        runtime != nil
    }

    init(
        windowBundle: TuringStoryWindowBundleController,
        heavyRuntimeRegistry: StoryHeavyRuntimeRegistry = .shared,
        chapterMusic: Chapter01MusicController = .shared,
        dadPrerecording: Chapter01DadWindowPrerecordingController =
            Chapter01DadWindowPrerecordingController()
    ) {
        self.windowBundle = windowBundle
        self.heavyRuntimeRegistry = heavyRuntimeRegistry
        self.chapterMusic = chapterMusic
        self.dadPrerecording = dadPrerecording
    }

    func validateAvailability() async throws {
        let context = try windowBundle.acquireChapter01DadCinematicContext()
        await windowBundle.releaseChapter01DadCinematicContext(
            reason: "chapter01DadAvailabilityValidated"
        )
        _ = context
        _ = try CharacterAttributeStore.shared.attributes(for: .dad)
        try await chapterMusic.prepare(catalog: Chapter01MusicCatalog.load())
        try await dadPrerecording.prepare()
    }

    func start(request: Chapter01DadWindowRequest) async throws {
        guard self.request == nil, runtime == nil else {
            throw Chapter01Error.openingResourceUnavailable(
                "Dad-window runtime is already active."
            )
        }
        try await StoryInteractionArbiter.shared.requireCurrent(
            request.storyTransitionLease
        )
        guard case .storyTransition = request.storyTransitionLease.owner else {
            throw StoryInteractionClaimError.invalidTransfer
        }
        try await dadPrerecording.prepare()

        state = .loading
        let context = try windowBundle.acquireChapter01DadCinematicContext()
        contextAcquired = true
        do {
            let prepared = try await Chapter01DadRuntimeFactory.prepare(
                chapterRunID: request.chapterRunID,
                context: context,
                heavyRuntimeRegistry: heavyRuntimeRegistry
            )
            self.request = request
            runtime = prepared
            generation &+= 1
            let currentGeneration = generation
            activeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.run(
                        request: request,
                        runtime: prepared,
                        generation: currentGeneration
                    )
                } catch is CancellationError {
                    await self.cleanup(reason: "dadWindowCancelled", notifyFailure: false)
                } catch {
                    self.state = .failed(error.localizedDescription)
                    await request.completionSink.dadWindowFailed(
                        Chapter01DadWindowFailureEvent(
                            chapterRunID: request.chapterRunID,
                            message: error.localizedDescription
                        )
                    )
                    await self.cleanup(reason: "dadWindowFailed", notifyFailure: false)
                }
            }
        } catch {
            await windowBundle.releaseChapter01DadCinematicContext(
                reason: "dadPreparationFailed"
            )
            contextAcquired = false
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func update(deltaTime: TimeInterval) {
        runtime?.controller?.update(
            deltaTime: Float(deltaTime),
            currentHeadPosition: nil
        )
        pathFollower.update(deltaTime: deltaTime)
    }

    func cancel(reason: String) async {
        guard request != nil || runtime != nil || contextAcquired else {
            state = .cancelled
            return
        }
        state = .cancelled
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        await cleanup(reason: reason, notifyFailure: false)
    }

    private func run(
        request: Chapter01DadWindowRequest,
        runtime: Chapter01DadRuntime,
        generation: UInt64
    ) async throws {
        try requireCurrent(request, generation: generation)
        state = .atEntry
        guard let controller = runtime.controller else {
            throw Chapter01Error.openingResourceUnavailable(
                "Dad controller released before playback."
            )
        }
        Chapter01DadRuntimeFactory.setController(
            controller,
            at: runtime.context.entryAnchor,
            relativeTo: runtime.context.portalWorldRoot
        )

        state = .walkingEntryToCenter
        try await followPath(
            controller: controller,
            from: runtime.context.entryAnchor,
            to: runtime.context.centerAnchor,
            coordinateSpace: runtime.context.portalWorldRoot,
            walkClipID: "unstable_walk_01",
            revealAfterLocomotionStarts: true
        )
        try requireCurrent(request, generation: generation)

        try await chapterMusic.play(
            .dadWindow,
            chapterRunID: request.chapterRunID
        )
        state = .turningLeftAtCenter
        try await playTurn(controller: controller, direction: .left)

        state = .centeredIdle20Seconds
        try controller.playScriptedIdleLoop(clipID: "idle_01")
        guard let exitTurnDurationSeconds =
                controller.durationForClip(id: "turn_right_90") else {
            throw Chapter01Error.openingResourceUnavailable(
                "Dad turn_right_90 duration is unavailable."
            )
        }
        let prerecordingStartDelay =
            try await dadPrerecording.scheduledStartDelaySeconds(
                centeredIdleDurationSeconds:
                    Self.centeredIdleDurationSeconds,
                exitTurnDurationSeconds:
                    TimeInterval(exitTurnDurationSeconds)
            )
        async let prerecordingPlayback: Void =
            dadPrerecording.playScheduled(
                after: prerecordingStartDelay,
                chapterRunID: request.chapterRunID
            )

        try await Task.sleep(
            for: .seconds(Self.centeredIdleDurationSeconds)
        )
        try requireCurrent(request, generation: generation)

        state = .turningRightToExit
        try await playTurn(controller: controller, direction: .right)
        try requireCurrent(request, generation: generation)

        state = .walkingCenterToExit
        try await followPath(
            controller: controller,
            from: runtime.context.centerAnchor,
            to: runtime.context.exitAnchor,
            coordinateSpace: runtime.context.portalWorldRoot,
            walkClipID: "unstable_walk_01",
            onLocomotionStarted: {
                try await request.completionSink.dadExitWalkStarted(
                    Chapter01DadExitWalkStartedEvent(
                        chapterRunID: request.chapterRunID,
                        storyTransitionLease: request.storyTransitionLease,
                        locomotionActuallyStarted: true
                    )
                )
            }
        )
        try await prerecordingPlayback

        state = .releasing
        let report = try await runtime.lease.release(
            reason: "dadReachedWindowExit"
        )
        self.runtime = nil
        await releaseWindowContext(reason: "dadReachedWindowExit")
        self.request = nil
        activeTask = nil
        state = .released
        await request.completionSink.dadRuntimeReleased(
            Chapter01DadRuntimeReleasedEvent(
                chapterRunID: request.chapterRunID,
                releaseReport: report
            )
        )
    }

    private func followPath(
        controller: JockRetargetTestController,
        from: Entity,
        to: Entity,
        coordinateSpace: Entity,
        walkClipID: String,
        revealAfterLocomotionStarts: Bool = false,
        onLocomotionStarted: (() async throws -> Void)? = nil
    ) async throws {
        let start = from.position(relativeTo: coordinateSpace)
        let destination = to.position(relativeTo: coordinateSpace)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pathContinuation = continuation
                do {
                    try pathFollower.begin(
                        controller: controller,
                        segments: [
                            ScriptedAnchorPathFollower.Segment(
                                fromID: from.name,
                                toID: to.name,
                                fromWorld: start,
                                toWorld: destination
                            )
                        ],
                        coordinateSpace: coordinateSpace,
                        walkClipID: walkClipID
                    ) { [weak self] in
                        self?.finishPath(.success(()))
                    }
                    if revealAfterLocomotionStarts {
                        controller.show()
                        print(
                            "[Chapter01Dad] entry locomotion submitted; Dad revealed"
                        )
                    }
                    if let onLocomotionStarted {
                        Task { @MainActor [weak self] in
                            do {
                                try await onLocomotionStarted()
                            } catch {
                                self?.pathFollower.cancel(
                                    reason: "dadExitHandoffFailed"
                                )
                                self?.finishPath(.failure(error))
                            }
                        }
                    }
                } catch {
                    finishPath(.failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.pathFollower.cancel(reason: "dadPathCancelled")
                self?.finishPath(.failure(CancellationError()))
            }
        }
    }

    private func playTurn(
        controller: JockRetargetTestController,
        direction: CharacterTurnDirection
    ) async throws {
        let token = UUID()
        activeTurnToken = token
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                turnContinuation = continuation
                do {
                    try controller.playScriptedTurn90(
                        direction: direction,
                        token: token
                    ) { [weak self] completedToken, result in
                        guard self?.activeTurnToken == completedToken else {
                            return
                        }
                        self?.finishTurn(result)
                    }
                } catch {
                    finishTurn(.failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                controller.cancelScriptedClipCompletion()
                self?.finishTurn(.failure(CancellationError()))
            }
        }
    }

    private func finishPath(_ result: Result<Void, Error>) {
        guard let continuation = pathContinuation else { return }
        pathContinuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func finishTurn(_ result: Result<Void, Error>) {
        guard let continuation = turnContinuation else { return }
        turnContinuation = nil
        activeTurnToken = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func cleanup(reason: String, notifyFailure: Bool) async {
        await dadPrerecording.cancel(reason: reason)
        pathFollower.cancel(reason: reason)
        finishPath(.failure(CancellationError()))
        runtime?.controller?.cancelScriptedClipCompletion()
        finishTurn(.failure(CancellationError()))
        if let runtime {
            _ = try? await runtime.lease.release(reason: reason)
        }
        runtime = nil
        await releaseWindowContext(reason: reason)
        request = nil
        activeTask = nil
    }

    private func releaseWindowContext(reason: String) async {
        guard contextAcquired else { return }
        contextAcquired = false
        await windowBundle.releaseChapter01DadCinematicContext(reason: reason)
    }

    private func requireCurrent(
        _ request: Chapter01DadWindowRequest,
        generation: UInt64
    ) throws {
        guard self.request?.chapterRunID == request.chapterRunID,
              self.generation == generation,
              !Task.isCancelled else {
            throw CancellationError()
        }
    }
}

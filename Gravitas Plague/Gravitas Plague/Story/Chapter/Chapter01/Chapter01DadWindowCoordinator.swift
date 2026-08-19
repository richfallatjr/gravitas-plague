import Foundation
import RealityKit
import simd

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
    private static let robotIntroStartSeconds: TimeInterval =
        centeredIdleDurationSeconds / 2

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
    private var activeWalkExpectedForward: SIMD3<Float>?
    private var previousWalkWorldPosition: SIMD3<Float>?
    private var activeWalkPhase: String?
    private var activeWalkDiagnosticWarningLogged = false
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
        guard let controller = runtime?.controller else { return }
        controller.update(
            deltaTime: Float(deltaTime),
            currentHeadPosition: nil
        )
        pathFollower.update(deltaTime: deltaTime)

        switch state {
        case .turningLeftAtCenter:
            if let route = runtime?.context.route {
                Chapter01DadRuntimeFactory.installWorldPose(
                    controller,
                    floorPosition: route.centerWorldPosition,
                    orientation: route.entryWalkWorldOrientation,
                    log: false
                )
            }
        case .centeredIdle20Seconds, .turningRightToExit:
            if let route = runtime?.context.route {
                Chapter01DadRuntimeFactory.installWorldPose(
                    controller,
                    floorPosition: route.centerWorldPosition,
                    orientation: route.centerFacingWindowWorldOrientation,
                    log: false
                )
            }
        default:
            break
        }

        sampleActiveWalkMotionDiagnostics(controller: controller)
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
        let route = runtime.context.route
        logRoute(route, chapterRunID: request.chapterRunID)
        Chapter01DadRuntimeFactory.installWorldPose(
            controller,
            floorPosition: route.entryWorldPosition,
            orientation: route.entryWalkWorldOrientation
        )

        state = .walkingEntryToCenter
        try await followPath(
            controller: controller,
            fromID: runtime.context.entryAnchorName,
            fromWorld: route.entryWorldPosition,
            toID: runtime.context.centerAnchorName,
            toWorld: route.centerWorldPosition,
            authoritativeWorldOrientation: route.entryWalkWorldOrientation,
            expectedWorldForward: route.entryWalkWorldForward,
            phase: "entryWalk",
            walkClipID: "unstable_walk_01",
            revealAfterLocomotionStarts: true
        )
        try requireCurrent(request, generation: generation)
        Chapter01DadRuntimeFactory.installWorldPose(
            controller,
            floorPosition: route.centerWorldPosition,
            orientation: route.entryWalkWorldOrientation
        )

        try await chapterMusic.play(
            .dadWindow,
            chapterRunID: request.chapterRunID
        )
        state = .turningLeftAtCenter
        try await playTurn(
            controller: controller,
            direction: .left,
            rootYawOwnership: .externalExactWorldPose
        )
        Chapter01DadRuntimeFactory.installWorldPose(
            controller,
            floorPosition: route.centerWorldPosition,
            orientation: route.centerFacingWindowWorldOrientation
        )
        logTurnEndpoint(
            controller: controller,
            orientation: route.centerFacingWindowWorldOrientation,
            phase: "leftTurn"
        )
        try requireRenderedAlignment(
            controller: controller,
            expectedForward: route.centerFacingWindowWorldForward,
            phase: "centerFacingWindow",
            visible: true
        )

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
            for: .seconds(Self.robotIntroStartSeconds)
        )
        try requireCurrent(request, generation: generation)
        try await request.completionSink.dadWindowMidpointReached(
            Chapter01DadWindowMidpointEvent(
                chapterRunID: request.chapterRunID,
                storyTransitionLease: request.storyTransitionLease,
                centeredIdleElapsedSeconds: Self.robotIntroStartSeconds,
                centeredIdleDurationSeconds: Self.centeredIdleDurationSeconds
            )
        )
        print(
            "[Chapter01Dad] authored midpoint reached; Robot portal intro started " +
                "elapsedSeconds=\(Self.robotIntroStartSeconds) " +
                "idleDurationSeconds=\(Self.centeredIdleDurationSeconds)"
        )
        try await Task.sleep(
            for: .seconds(
                Self.centeredIdleDurationSeconds -
                    Self.robotIntroStartSeconds
            )
        )
        try requireCurrent(request, generation: generation)

        state = .turningRightToExit
        Chapter01DadRuntimeFactory.installWorldPose(
            controller,
            floorPosition: route.centerWorldPosition,
            orientation: route.centerFacingWindowWorldOrientation
        )
        try await playTurn(
            controller: controller,
            direction: .right,
            rootYawOwnership: .externalExactWorldPose
        )
        Chapter01DadRuntimeFactory.installWorldPose(
            controller,
            floorPosition: route.centerWorldPosition,
            orientation: route.exitWalkWorldOrientation
        )
        logTurnEndpoint(
            controller: controller,
            orientation: route.exitWalkWorldOrientation,
            phase: "rightTurn"
        )
        try requireRenderedAlignment(
            controller: controller,
            expectedForward: route.exitWalkWorldForward,
            phase: "exitWalkAfterTurn",
            visible: true
        )
        try requireCurrent(request, generation: generation)

        state = .walkingCenterToExit
        try await followPath(
            controller: controller,
            fromID: runtime.context.centerAnchorName,
            fromWorld: route.centerWorldPosition,
            toID: runtime.context.exitAnchorName,
            toWorld: route.exitWorldPosition,
            authoritativeWorldOrientation: route.exitWalkWorldOrientation,
            expectedWorldForward: route.exitWalkWorldForward,
            phase: "exitWalk",
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
        Chapter01DadRuntimeFactory.installWorldPose(
            controller,
            floorPosition: route.exitWorldPosition,
            orientation: route.exitWalkWorldOrientation
        )
        controller.rootEntity.isEnabled = false
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
        fromID: String,
        fromWorld: SIMD3<Float>,
        toID: String,
        toWorld: SIMD3<Float>,
        authoritativeWorldOrientation: simd_quatf,
        expectedWorldForward: SIMD3<Float>,
        phase: String,
        walkClipID: String,
        revealAfterLocomotionStarts: Bool = false,
        onLocomotionStarted: (() async throws -> Void)? = nil
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pathContinuation = continuation
                do {
                    activeWalkExpectedForward = expectedWorldForward
                    activeWalkPhase = phase
                    previousWalkWorldPosition = fromWorld
                    activeWalkDiagnosticWarningLogged = false
                    try pathFollower.begin(
                        controller: controller,
                        segments: [
                            ScriptedAnchorPathFollower.Segment(
                                fromID: fromID,
                                toID: toID,
                                fromWorld: fromWorld,
                                toWorld: toWorld
                            )
                        ],
                        coordinateSpace: nil,
                        walkClipID: walkClipID,
                        authoritativeWorldOrientation:
                            authoritativeWorldOrientation,
                        transitionToWalkClip: false
                    ) { [weak self] in
                        self?.finishPath(.success(()))
                    }
                    try requireRenderedAlignment(
                        controller: controller,
                        expectedForward: expectedWorldForward,
                        phase: phase,
                        visible: !revealAfterLocomotionStarts
                    )
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
                    pathFollower.cancel(reason: "dadPathStartFailed")
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
        direction: CharacterTurnDirection,
        rootYawOwnership: ScriptedRootYawOwnership
    ) async throws {
        let token = UUID()
        activeTurnToken = token
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                turnContinuation = continuation
                do {
                    try controller.playScriptedTurn90(
                        direction: direction,
                        rootYawOwnership: rootYawOwnership,
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
        activeWalkExpectedForward = nil
        previousWalkWorldPosition = nil
        activeWalkPhase = nil
        activeWalkDiagnosticWarningLogged = false
        guard let continuation = pathContinuation else { return }
        pathContinuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func requireRenderedAlignment(
        controller: JockRetargetTestController,
        expectedForward: SIMD3<Float>,
        phase: String,
        visible: Bool
    ) throws {
        let snapshot = try controller.scriptedCharacterHeadingSnapshot()
        let expected = try PortalLocalHeadingResolver.normalizedHorizontal(
            expectedForward,
            label: "\(phase).expected"
        )
        let rendered = try PortalLocalHeadingResolver.normalizedHorizontal(
            snapshot.renderedVisualForwardWorld,
            label: "\(phase).rendered"
        )
        let angle = try PortalLocalHeadingResolver.angularErrorRadians(
            rendered,
            expected
        )
        let degrees = angle * 180 / Float.pi
        let withinTolerance = angle <= 5 * Float.pi / 180

        print(
            """
            [Chapter01DadHeading] alignment sampled
              phase: \(phase)
              logicalRootForwardWorld: \(snapshot.logicalRootForwardWorld)
              renderedVisualForwardWorld: \(snapshot.renderedVisualForwardWorld)
              expectedForwardWorld: \(expected)
              renderedAlignmentDegrees: \(degrees)
              withinTolerance: \(withinTolerance)
              visible: \(visible)
            """
        )

        guard withinTolerance || visible else {
            throw Chapter01Error.openingResourceUnavailable(
                "Dad rendered heading mismatch during \(phase): \(degrees) degrees."
            )
        }

        if !withinTolerance {
            print(
                "[Chapter01DadHeading] WARNING visible heading mismatch retained for diagnostics phase=\(phase) degrees=\(degrees) progressionCancelled=false"
            )
        }
    }

    private func sampleActiveWalkMotionDiagnostics(
        controller: JockRetargetTestController
    ) {
        // The hidden pre-reveal alignment check is the production gate. This
        // animated sample is telemetry and must never cancel the cinematic.
        guard let expectedForward = activeWalkExpectedForward,
              let previous = previousWalkWorldPosition,
              let phase = activeWalkPhase else {
            return
        }

        let current = controller.rootEntity.position(relativeTo: nil)
        previousWalkWorldPosition = current
        let displacement = current - previous
        let horizontalDistance = simd_length(
            SIMD3<Float>(displacement.x, 0, displacement.z)
        )
        guard horizontalDistance > 0.002 else { return }

        do {
            let travel = try PortalLocalHeadingResolver.normalizedHorizontal(
                displacement,
                label: "\(phase).displacement"
            )
            let expected = try PortalLocalHeadingResolver.normalizedHorizontal(
                expectedForward,
                label: "\(phase).expectedTravel"
            )
            let heading = try controller.scriptedCharacterHeadingSnapshot()
            let rendered = try PortalLocalHeadingResolver.normalizedHorizontal(
                heading.renderedVisualForwardWorld,
                label: "\(phase).renderedTravel"
            )
            let travelAgreement = simd_dot(travel, expected)
            let renderedAgreement = simd_dot(travel, rendered)
            let minimumAgreement = cos(15 * Float.pi / 180)

            guard travelAgreement >= minimumAgreement,
                  renderedAgreement >= minimumAgreement else {
                if !activeWalkDiagnosticWarningLogged {
                    activeWalkDiagnosticWarningLogged = true
                    print(
                        """
                        [Chapter01DadHeading] WARNING walk-alignment diagnostic
                          phase: \(phase)
                          displacementWorld: \(displacement)
                          travelWorld: \(travel)
                          expectedWorld: \(expected)
                          renderedForwardWorld: \(rendered)
                          travelAgreement: \(travelAgreement)
                          renderedAgreement: \(renderedAgreement)
                          progressionCancelled: false
                          reason: diagnostic_has_no_production_authority
                        """
                    )
                }
                return
            }

            if activeWalkDiagnosticWarningLogged {
                print(
                    "[Chapter01DadHeading] walk alignment recovered phase=\(phase) progressionCancelled=false"
                )
                activeWalkDiagnosticWarningLogged = false
            }
        } catch {
            if !activeWalkDiagnosticWarningLogged {
                activeWalkDiagnosticWarningLogged = true
                print(
                    "[Chapter01DadHeading] WARNING diagnostic sampling failed phase=\(phase) error=\(error.localizedDescription) progressionCancelled=false"
                )
            }
        }
    }

    private func logRoute(
        _ route: Chapter01DadWindowRouteSnapshot,
        chapterRunID: UUID
    ) {
        print(
            """
            [Chapter01DadHeading] route captured
              chapterRunID: \(chapterRunID.uuidString)
              windowWorldTransform: \(route.windowWorldTransform)
              entryWorldPosition: \(route.entryWorldPosition)
              centerWorldPosition: \(route.centerWorldPosition)
              exitWorldPosition: \(route.exitWorldPosition)
              entryRouteTangentWorld: \(route.entryWalkWorldForward)
              centerFacingWindowWorld: \(route.centerFacingWindowWorldForward)
              exitRouteTangentWorld: \(route.exitWalkWorldForward)
              entryWorldYawDegrees: \(Self.yawDegrees(route.entryWalkWorldOrientation))
              centerWorldYawDegrees: \(Self.yawDegrees(route.centerFacingWindowWorldOrientation))
              exitWorldYawDegrees: \(Self.yawDegrees(route.exitWalkWorldOrientation))
              entryToCenterSignedTurnDegrees: \(route.entryToCenterSignedTurnRadians * 180 / Float.pi)
              centerToExitSignedTurnDegrees: \(route.centerToExitSignedTurnRadians * 180 / Float.pi)
            """
        )
    }

    private func logTurnEndpoint(
        controller: JockRetargetTestController,
        orientation: simd_quatf,
        phase: String
    ) {
        print(
            """
            [Chapter01DadHeading] exact endpoint committed
              phase: \(phase)
              rootYawOwnership: externalExactWorldPose
              expectedWorldOrientation: \(orientation.vector)
              actualWorldOrientation: \(controller.rootEntity.orientation(relativeTo: nil).vector)
              commitCount: 1
            """
        )
    }

    private nonisolated static func yawDegrees(
        _ orientation: simd_quatf
    ) -> Float {
        let forward = orientation.act(SIMD3<Float>(0, 0, -1))
        return atan2(forward.x, -forward.z) * 180 / Float.pi
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

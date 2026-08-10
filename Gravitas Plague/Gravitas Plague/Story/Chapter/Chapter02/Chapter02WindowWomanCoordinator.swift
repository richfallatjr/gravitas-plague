import Foundation
import RealityKit
import simd

@MainActor
protocol Chapter02WindowWomanCompletionSink: AnyObject {
    func womanStagedForDoor(
        _ event: Chapter02WomanStagedForDoorEvent
    ) async throws
    func womanWindowFailed(chapterRunID: UUID, message: String) async
}

@MainActor
final class Chapter02WindowWomanCoordinator {
    static let idleDurationSeconds: TimeInterval = 20

    private let windowBundle: TuringStoryWindowBundleController
    private let sceneRoot: Entity
    private let stagingRoot = Entity()
    private let pathFollower = ScriptedAnchorPathFollower()
    private let richPR = Chapter02PrerecordingPlayer()

    private(set) var state: Chapter02WindowWomanState = .unloaded
    private(set) var runtime: Chapter02WindowWomanRuntime?
    private weak var completionSink:
        (any Chapter02WindowWomanCompletionSink)?
    private var chapterRunID: UUID?
    private var activeTask: Task<Void, Never>?
    private var pathContinuation: CheckedContinuation<Void, Error>?
    private var clipContinuation: CheckedContinuation<Void, Error>?
    private var activeClipToken: UUID?
    private var generation: UInt64 = 0
    private var contextAcquired = false

    init(
        windowBundle: TuringStoryWindowBundleController,
        sceneRoot: Entity
    ) {
        self.windowBundle = windowBundle
        self.sceneRoot = sceneRoot
        stagingRoot.name = "Chapter02WomanNeutralStagingRoot"
        stagingRoot.isEnabled = false
        sceneRoot.addChild(stagingRoot)
    }

    func prepareHidden(
        chapterRunID: UUID,
        completionSink: any Chapter02WindowWomanCompletionSink
    ) async throws {
        guard runtime == nil else {
            throw Chapter02Error.womanRuntimeUnavailable(
                "another spouse source is already active"
            )
        }
        state = .loading
        let context = try windowBundle.acquireChapter01DadCinematicContext()
        contextAcquired = true
        do {
            runtime = try await Chapter02WindowWomanRuntimeFactory.prepare(
                chapterRunID: chapterRunID,
                context: context,
                sceneRoot: sceneRoot
            )
            self.chapterRunID = chapterRunID
            self.completionSink = completionSink
            generation &+= 1
            state = .atEntry
        } catch {
            await windowBundle.releaseChapter01DadCinematicContext(
                reason: "chapter02WomanPreparationFailed"
            )
            contextAcquired = false
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func activatePresentation() throws {
        guard activeTask == nil,
              let runtime,
              let chapterRunID else {
            throw Chapter02Error.womanRuntimeUnavailable(
                "hidden presentation source was not prepared"
            )
        }
        let currentGeneration = generation
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.runPresentation(
                    runtime: runtime,
                    chapterRunID: chapterRunID,
                    generation: currentGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                self.state = .failed(error.localizedDescription)
                await self.completionSink?.womanWindowFailed(
                    chapterRunID: chapterRunID,
                    message: error.localizedDescription
                )
            }
        }
    }

    func stageHiddenRuntimeForDoor() async throws {
        guard activeTask == nil,
              let runtime,
              let controller = runtime.controller else {
            throw Chapter02Error.invalidRuntimeTransfer(
                "hidden source is unavailable for direct battle continuation"
            )
        }
        let worldTransform = controller.rootEntity.transformMatrix(relativeTo: nil)
        controller.rootEntity.removeFromParent()
        stagingRoot.addChild(controller.rootEntity)
        controller.rootEntity.setTransformMatrix(worldTransform, relativeTo: nil)
        controller.rootEntity.isEnabled = false
        try runtime.lease.markPortalIntro()
        if contextAcquired {
            await windowBundle.releaseChapter01DadCinematicContext(
                reason: "chapter02WomanDirectBattleContinuation"
            )
            contextAcquired = false
        }
        state = .stagedForDoor
    }

    func takeStagedRuntime() throws -> Chapter02WindowWomanRuntime {
        guard state == .stagedForDoor, let runtime else {
            throw Chapter02Error.invalidRuntimeTransfer(
                "woman has not reached the neutral staging root"
            )
        }
        self.runtime = nil
        state = .transferredToPortalIntro
        return runtime
    }

    func update(deltaTime: TimeInterval) {
        guard let controller = runtime?.controller else { return }
        controller.update(
            deltaTime: Float(deltaTime),
            currentHeadPosition: nil
        )
        pathFollower.update(deltaTime: deltaTime)
        switch state {
        case .turningLeftAtCenter,
             .centeredIdle20Seconds,
             .turningRightToExit:
            let route = runtime?.context.route
            if let route {
                let orientation = state == .turningLeftAtCenter
                    ? route.entryWalkWorldOrientation
                    : route.centerFacingWindowWorldOrientation
                Chapter02WindowWomanRuntimeFactory.installWorldPose(
                    controller,
                    floorPosition: route.centerWorldPosition,
                    orientation: orientation
                )
            }
        default:
            break
        }
    }

    func cancel(reason: String) async {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        pathFollower.cancel(reason: reason)
        finishPath(.failure(CancellationError()))
        runtime?.controller?.cancelScriptedClipCompletion()
        finishClip(.failure(CancellationError()))
        await richPR.cancel(reason: reason)
        if let lease = runtime?.lease {
            _ = try? await lease.release(reason: .storyReset)
        }
        runtime = nil
        chapterRunID = nil
        completionSink = nil
        if contextAcquired {
            await windowBundle.releaseChapter01DadCinematicContext(
                reason: reason
            )
            contextAcquired = false
        }
        state = .cancelled
    }

    private func runPresentation(
        runtime: Chapter02WindowWomanRuntime,
        chapterRunID: UUID,
        generation: UInt64
    ) async throws {
        guard let controller = runtime.controller else {
            throw Chapter02Error.womanRuntimeUnavailable("controller released")
        }
        let route = runtime.context.route
        Chapter02WindowWomanRuntimeFactory.installWorldPose(
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
            orientation: route.entryWalkWorldOrientation,
            reveal: true
        )
        try requireCurrent(generation)
        Chapter02WindowWomanRuntimeFactory.installWorldPose(
            controller,
            floorPosition: route.centerWorldPosition,
            orientation: route.entryWalkWorldOrientation
        )
        state = .turningLeftAtCenter
        try await playTurn(controller: controller, direction: .left)
        Chapter02WindowWomanRuntimeFactory.installWorldPose(
            controller,
            floorPosition: route.centerWorldPosition,
            orientation: route.centerFacingWindowWorldOrientation
        )
        try await performExit(
            controller: controller,
            runtime: runtime,
            chapterRunID: chapterRunID,
            generation: generation
        )
    }

    private func performExit(
        controller: JockRetargetTestController,
        runtime: Chapter02WindowWomanRuntime,
        chapterRunID: UUID,
        generation: UInt64
    ) async throws {
        let route = runtime.context.route
        try controller.playScriptedIdleLoop(clipID: "idle_01")
        try await Chapter02BattleMusicActor.shared.startIfNeeded(
            reason: "chapter02WomanWindow.richPRCue"
        )
        async let richPlayback: Void = richPR.play(
            resourcePath:
                "Turing/Audio/prerecordings/pr-rich-women-window.mp3",
            runID: "chapter02.windowExit.\(chapterRunID.uuidString)",
            label: "chapter02.windowRecognition"
        )
        state = .centeredIdle20Seconds
        try await Task.sleep(for: .seconds(Self.idleDurationSeconds))
        try requireCurrent(generation)

        state = .turningRightToExit
        try await playTurn(controller: controller, direction: .right)
        Chapter02WindowWomanRuntimeFactory.installWorldPose(
            controller,
            floorPosition: route.centerWorldPosition,
            orientation: route.exitWalkWorldOrientation
        )
        state = .walkingCenterToExit
        try await followPath(
            controller: controller,
            fromID: runtime.context.centerAnchorName,
            fromWorld: route.centerWorldPosition,
            toID: runtime.context.exitAnchorName,
            toWorld: route.exitWorldPosition,
            orientation: route.exitWalkWorldOrientation,
            reveal: false
        )
        Chapter02WindowWomanRuntimeFactory.installWorldPose(
            controller,
            floorPosition: route.exitWorldPosition,
            orientation: route.exitWalkWorldOrientation
        )
        controller.rootEntity.isEnabled = false
        try await richPlayback

        let worldTransform = controller.rootEntity.transformMatrix(relativeTo: nil)
        controller.rootEntity.removeFromParent()
        stagingRoot.addChild(controller.rootEntity)
        controller.rootEntity.setTransformMatrix(worldTransform, relativeTo: nil)
        controller.cancelScriptedClipCompletion()
        try runtime.lease.markPortalIntro()
        if contextAcquired {
            await windowBundle.releaseChapter01DadCinematicContext(
                reason: "chapter02WomanStagedForDoor"
            )
            contextAcquired = false
        }
        activeTask = nil
        state = .stagedForDoor
        try await completionSink?.womanStagedForDoor(
            Chapter02WomanStagedForDoorEvent(chapterRunID: chapterRunID)
        )
    }

    private func followPath(
        controller: JockRetargetTestController,
        fromID: String,
        fromWorld: SIMD3<Float>,
        toID: String,
        toWorld: SIMD3<Float>,
        orientation: simd_quatf,
        reveal: Bool
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pathContinuation = continuation
                do {
                    try pathFollower.begin(
                        controller: controller,
                        segments: [
                            .init(
                                fromID: fromID,
                                toID: toID,
                                fromWorld: fromWorld,
                                toWorld: toWorld
                            )
                        ],
                        coordinateSpace: nil,
                        walkClipID: "unstable_walk_01",
                        authoritativeWorldOrientation: orientation,
                        transitionToWalkClip: false
                    ) { [weak self] in
                        self?.finishPath(.success(()))
                    }
                    if reveal {
                        controller.show()
                    }
                } catch {
                    finishPath(.failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.pathFollower.cancel(reason: "chapter02WomanPathCancelled")
                self?.finishPath(.failure(CancellationError()))
            }
        }
    }

    private func playTurn(
        controller: JockRetargetTestController,
        direction: CharacterTurnDirection
    ) async throws {
        let token = UUID()
        activeClipToken = token
        try await withCheckedThrowingContinuation { continuation in
            clipContinuation = continuation
            do {
                try controller.playScriptedTurn90(
                    direction: direction,
                    rootYawOwnership: .externalExactWorldPose,
                    token: token
                ) { [weak self] returned, result in
                    guard self?.activeClipToken == returned else { return }
                    self?.finishClip(result)
                }
            } catch {
                finishClip(.failure(error))
            }
        }
    }

    private func finishPath(_ result: Result<Void, Error>) {
        guard let continuation = pathContinuation else { return }
        pathContinuation = nil
        continuation.resume(with: result)
    }

    private func finishClip(_ result: Result<Void, Error>) {
        activeClipToken = nil
        guard let continuation = clipContinuation else { return }
        clipContinuation = nil
        continuation.resume(with: result)
    }

    private func requireCurrent(_ expectedGeneration: UInt64) throws {
        guard generation == expectedGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
    }
}

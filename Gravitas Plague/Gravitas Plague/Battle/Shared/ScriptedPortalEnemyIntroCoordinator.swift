import Foundation
import RealityKit
import simd

@MainActor
final class ScriptedPortalEnemyIntroCoordinator {
    enum IntroError: LocalizedError {
        case cancelled(String)
        case staleTurnCompletion

        var errorDescription: String? {
            switch self {
            case .cancelled(let reason):
                return "Scripted portal intro cancelled: \(reason)"
            case .staleTurnCompletion:
                return "Scripted turn returned a stale completion token."
            }
        }
    }

    private let clock: any BattleClock
    private let follower = ScriptedAnchorPathFollower()
    private var prepared: Battle01PreparedEnemy?
    private var doorContext: TuringStoryDoorBattlePortalContext?
    private var definition: Battle01Definition?
    private var pathContinuation: CheckedContinuation<Void, Error>?
    private var turnContinuation: CheckedContinuation<Void, Error>?
    private var activeTurnToken: UUID?
    private var onStateChange: ((Battle01State) -> Void)?

    init(clock: any BattleClock) {
        self.clock = clock
    }

    func install(
        prepared: Battle01PreparedEnemy,
        doorContext: TuringStoryDoorBattlePortalContext,
        definition: Battle01Definition,
        onStateChange: @escaping (Battle01State) -> Void
    ) {
        self.prepared = prepared
        self.doorContext = doorContext
        self.definition = definition
        self.onStateChange = onStateChange
    }

    func performApproach() async throws {
        guard let prepared,
              let doorContext,
              let definition else {
            throw IntroError.cancelled("notInstalled")
        }

        try prepared.sourceController.playScriptedIdleLoop()
        onStateChange?(.portalIdleFacingAway)
        print("[Battle01] idle started durationSeconds=\(definition.enemy.idleDurationSeconds)")
        try await clock.sleep(for: .seconds(definition.enemy.idleDurationSeconds))
        try Task.checkCancellation()
        print("[Battle01] idle completed")

        for turnIndex in 1...definition.enemy.turnCount {
            onStateChange?(turnIndex == 1 ? .turnOne : .turnTwo)
            try await playRightTurn(
                controller: prepared.sourceController,
                turnIndex: turnIndex,
                expectedDegrees: definition.enemy.turnDegreesPerCompletion
            )
        }

        let a1 = doorContext.zombieA1.position(relativeTo: nil)
        let a2 = doorContext.zombieA2.position(relativeTo: nil)
        let a3 = doorContext.zombieA3.position(relativeTo: nil)
        let tangent = simd_normalize(a2 - a1)
        let forward = prepared.sourceRoot.orientation(relativeTo: nil).act(
            SIMD3<Float>(0, 0, -1)
        )
        let flatTangent = simd_normalize(SIMD3<Float>(tangent.x, 0, tangent.z))
        let flatForward = simd_normalize(SIMD3<Float>(forward.x, 0, forward.z))
        let angle = acos(min(1, max(-1, simd_dot(flatForward, flatTangent)))) * 180 / .pi
        print("[Battle01] post-turn path alignment degrees=\(angle)")

        onStateChange?(.approachingDoor)
        try await follow(
            controller: prepared.sourceController,
            segments: [
                .init(fromID: "zombie_a1", toID: "zombie_a2", fromWorld: a1, toWorld: a2),
                .init(fromID: "zombie_a2", toID: "zombie_a3", fromWorld: a2, toWorld: a3)
            ]
        )
        print("[Battle01] arrived at door threshold")
    }

    func performPortalCrossing() async throws {
        guard let prepared,
              let doorContext,
              let definition else {
            throw IntroError.cancelled("notInstalled")
        }
        onStateChange?(.portalCrossing)
        let a3 = doorContext.zombieA3.position(relativeTo: nil)
        let target = prepared.portalMirror.roomSideTarget(
            distance: definition.portalHandoff.exitThresholdPortalLocalZMeters + 0.35,
            floorY: a3.y
        )
        try await follow(
            controller: prepared.sourceController,
            segments: [
                .init(
                    fromID: "zombie_a3",
                    toID: "portal_room_exit",
                    fromWorld: a3,
                    toWorld: target
                )
            ]
        )
        prepared.sourceRoot.isEnabled = true
        if !prepared.portalMirror.exited {
            prepared.portalMirror.cleanup(reason: "Battle01.crossingPathCompleted")
        }
    }

    func update(deltaTime: TimeInterval) {
        guard let prepared,
              let definition else { return }
        prepared.sourceController.update(
            deltaTime: Float(deltaTime),
            currentHeadPosition: nil
        )
        follower.update(deltaTime: deltaTime)
        prepared.portalMirror.sync(
            revealThreshold: definition.portalHandoff.revealThresholdPortalLocalZMeters,
            exitThreshold: definition.portalHandoff.exitThresholdPortalLocalZMeters
        )
    }

    func cancel(reason: String, removeSource: Bool = true) {
        follower.cancel(reason: reason)
        activeTurnToken = nil
        let pendingTurn = turnContinuation
        turnContinuation = nil
        pendingTurn?.resume(throwing: IntroError.cancelled(reason))
        prepared?.sourceController.cancelScriptedClipCompletion()
        pathContinuation?.resume(throwing: IntroError.cancelled(reason))
        pathContinuation = nil
        prepared?.portalMirror.cleanup(reason: reason)
        if removeSource {
            prepared?.sourceController.hide()
            prepared?.sourceRoot.removeFromParent()
        }
        prepared = nil
        doorContext = nil
        definition = nil
        onStateChange = nil
    }

    private func playRightTurn(
        controller: JockRetargetTestController,
        turnIndex: Int,
        expectedDegrees: Float
    ) async throws {
        let token = UUID()
        print("[Battle01] turn started turnIndex=\(turnIndex) token=\(token.uuidString)")
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            activeTurnToken = token
            turnContinuation = continuation
            do {
                try controller.playScriptedRightTurn90(token: token) { [weak self] returnedToken, result in
                    self?.completeTurn(token: returnedToken, result: result)
                }
            } catch {
                activeTurnToken = nil
                turnContinuation = nil
                continuation.resume(throwing: error)
            }
        }
        try Task.checkCancellation()
        print(
            "[Battle01] turn completed turnIndex=\(turnIndex) expectedDegrees=\(expectedDegrees) authoredRuntimeYawCommit=true manualYawCommit=false"
        )
    }

    private func completeTurn(
        token: UUID,
        result: Result<Void, Error>
    ) {
        guard activeTurnToken == token else {
            print("[Battle01] stale turn completion ignored token=\(token.uuidString)")
            return
        }
        activeTurnToken = nil
        let pending = turnContinuation
        turnContinuation = nil
        pending?.resume(with: result)
    }

    private func follow(
        controller: JockRetargetTestController,
        segments: [ScriptedAnchorPathFollower.Segment]
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            pathContinuation = continuation
            do {
                try follower.begin(controller: controller, segments: segments) { [weak self] in
                    guard let self else { return }
                    let completion = self.pathContinuation
                    self.pathContinuation = nil
                    completion?.resume()
                }
            } catch {
                pathContinuation = nil
                continuation.resume(throwing: error)
            }
        }
        try Task.checkCancellation()
    }
}

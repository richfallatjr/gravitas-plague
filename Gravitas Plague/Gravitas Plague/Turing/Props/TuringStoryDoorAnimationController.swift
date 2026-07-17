import Foundation
import RealityKit
import simd

@MainActor
final class TuringStoryDoorAnimationController {
    enum DoorAnimationError: LocalizedError {
        case interrupted(String)

        var errorDescription: String? {
            switch self {
            case .interrupted(let reason):
                return "Door animation was interrupted: \(reason)"
            }
        }
    }

    enum DoorState: String, Sendable {
        case closed
        case opening
        case open
        case closing
    }

    private enum SFX {
        static let subdirectory = "Turing/Audio/door"
        static let openCandidates = [
            "door-open-creak-01.wav",
            "door-open-creak-02.wav",
            "door-open-creak-03.wav",
            "door-open-creak-04.wav"
        ]
        static let closeSqueak = "door-close-squeak-01.wav"
        static let closeContact = "door-close-contact-01.wav"
    }

    private let hingePivot: Entity
    private let audioEmitter: Entity
    private let closedRotation: simd_quatf
    private let openYawRadians: Float
    private let openDuration: TimeInterval
    private let closeDuration: TimeInterval
    private let onStateChanged: (DoorState) -> Void
    private let hingeRotationAxis = SIMD3<Float>(0, 0, 1)
    private(set) var state: DoorState = .closed
    private var currentYawRadians: Float = 0
    private var animationTask: Task<Void, Never>?
    private var openWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var closeWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var sfxControllersByID: [UUID: AudioPlaybackController] = [:]
    private var sfxEntitiesByID: [UUID: Entity] = [:]
    private var pendingCloseSFXIDs = Set<UUID>()
    private var closeVisualAnimationCompleted = false

    init(
        hingePivot: Entity,
        audioEmitter: Entity,
        openYawDegrees: Float = -145.0,
        openDuration: TimeInterval = 1.15,
        closeDuration: TimeInterval = 0.95,
        onStateChanged: @escaping (DoorState) -> Void = { _ in }
    ) {
        self.hingePivot = hingePivot
        self.audioEmitter = audioEmitter
        self.closedRotation = hingePivot.transform.rotation
        self.openYawRadians = openYawDegrees * .pi / 180.0
        self.openDuration = openDuration
        self.closeDuration = closeDuration
        self.onStateChanged = onStateChanged
    }

    func toggle(
        reason: String
    ) {
        switch state {
        case .closed,
             .closing:
            open(reason: reason)

        case .open,
             .opening:
            close(reason: reason)
        }
    }

    func open(
        reason: String
    ) {
        guard state != .open,
              state != .opening else {
            return
        }
        failCloseWaiters(reason: "openRequested.\(reason)")
        pendingCloseSFXIDs.removeAll(keepingCapacity: false)
        closeVisualAnimationCompleted = false
        let openSFX = randomOpenSFX()
        startAnimation(
            targetState: .open,
            fromDegrees: currentYawDegrees(),
            toDegrees: openYawRadians * 180.0 / .pi,
            duration: openDuration,
            startSFX: openSFX,
            completionSFX: nil,
            reason: reason
        )
    }

    func close(
        reason: String
    ) {
        guard state != .closed else {
            resumeCloseWaiters()
            return
        }
        failOpenWaiters(reason: "closeRequested.\(reason)")
        startAnimation(
            targetState: .closed,
            fromDegrees: currentYawDegrees(),
            toDegrees: 0,
            duration: closeDuration,
            startSFX: SFX.closeSqueak,
            completionSFX: SFX.closeContact,
            reason: reason
        )
    }

    func cancel(
        reason: String
    ) {
        animationTask?.cancel()
        animationTask = nil
        failOpenWaiters(reason: reason)
        failCloseWaiters(reason: reason)
        closeVisualAnimationCompleted = false
        stopSFX(reason: reason)
    }

    func setStateImmediatelyForStoryTeleport(
        _ target: DoorState,
        teleportID: UUID
    ) {
        animationTask?.cancel()
        animationTask = nil
        failOpenWaiters(reason: "storyTeleport.\(teleportID.uuidString)")
        failCloseWaiters(reason: "storyTeleport.\(teleportID.uuidString)")
        closeVisualAnimationCompleted = false
        stopSFX(reason: "storyTeleport.\(teleportID.uuidString)")

        switch target {
        case .closed, .closing:
            applyYaw(0)
            state = .closed
        case .open, .opening:
            applyYaw(openYawRadians)
            state = .open
        }
        onStateChanged(state)

        print("""
        [TuringDoorAnimation] Story teleport endpoint applied
          teleportID: \(teleportID.uuidString)
          state: \(state.rawValue)
          animated: false
        """)
    }

    func openAndWait(
        reason: String
    ) async throws {
        if state == .open {
            return
        }

        let waiterID = UUID()
        try await withCheckedThrowingContinuation { continuation in
            openWaiters[waiterID] = continuation
            if state != .opening {
                open(reason: reason)
            }
        }
    }

    func closeAndWait(reason: String) async throws {
        if state == .closed { return }

        let waiterID = UUID()
        try await withCheckedThrowingContinuation { continuation in
            closeWaiters[waiterID] = continuation
            if state != .closing {
                close(reason: reason)
            }
        }
    }

    private func startAnimation(
        targetState: DoorState,
        fromDegrees: Float,
        toDegrees: Float,
        duration: TimeInterval,
        startSFX: String,
        completionSFX: String?,
        reason: String
    ) {
        animationTask?.cancel()
        let startYaw = fromDegrees * .pi / 180.0
        let endYaw = toDegrees * .pi / 180.0
        let startingState: DoorState = targetState == .open ? .opening : .closing
        if targetState == .closed {
            pendingCloseSFXIDs.removeAll(keepingCapacity: false)
            closeVisualAnimationCompleted = false
        }
        state = startingState
        onStateChanged(state)

        playSFX(
            fileName: startSFX,
            label: targetState == .open ? "door.open.creak" : "door.close.squeak",
            participatesInCloseCompletion: targetState == .closed
        )

        print(
            """
            [TuringDoorAnimation] \(targetState == .open ? "open" : "close") started
              fromDegrees: \(fromDegrees)
              toDegrees: \(toDegrees)
              easing: smoothstep
              hingeAxis: localZ
              sfx: \(startSFX)
              reason: \(reason)
            """
        )

        animationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let frameSeconds = 1.0 / 60.0
            let frameCount = max(
                1,
                Int(ceil(duration / frameSeconds))
            )

            for frame in 0...frameCount {
                if Task.isCancelled {
                    return
                }

                let rawT = Float(frame) / Float(frameCount)
                let smooth = rawT * rawT * (3.0 - 2.0 * rawT)
                let yaw = startYaw + (endYaw - startYaw) * smooth
                self.applyYaw(yaw)

                if frame < frameCount {
                    try? await Task.sleep(
                        nanoseconds: UInt64(frameSeconds * 1_000_000_000)
                    )
                }
            }

            self.animationTask = nil
            if targetState == .open {
                self.state = .open
                self.onStateChanged(self.state)
                self.resumeOpenWaiters()
                print("[TuringDoorAnimation] open completed state=\(self.state.rawValue)")
            } else {
                self.closeVisualAnimationCompleted = true
                if let completionSFX {
                    self.playSFX(
                        fileName: completionSFX,
                        label: "door.close.contact",
                        participatesInCloseCompletion: true
                    )
                    print("[TuringDoorAnimation] close contact sfx=\(completionSFX)")
                }
                self.finalizeCloseIfReady()
            }
        }
    }

    private func applyYaw(
        _ yaw: Float
    ) {
        currentYawRadians = yaw
        hingePivot.transform.rotation =
            closedRotation *
            simd_quatf(
                angle: yaw,
                axis: hingeRotationAxis
            )
    }

    private func currentYawDegrees() -> Float {
        currentYawRadians * 180.0 / .pi
    }

    private func resumeOpenWaiters() {
        let waiters = openWaiters.values
        openWaiters.removeAll(keepingCapacity: false)
        for continuation in waiters {
            continuation.resume()
        }
    }

    private func failOpenWaiters(reason: String) {
        let waiters = openWaiters.values
        openWaiters.removeAll(keepingCapacity: false)
        for continuation in waiters {
            continuation.resume(
                throwing: DoorAnimationError.interrupted(reason)
            )
        }
    }

    private func resumeCloseWaiters() {
        let waiters = closeWaiters.values
        closeWaiters.removeAll(keepingCapacity: false)
        for continuation in waiters {
            continuation.resume()
        }
    }

    private func failCloseWaiters(reason: String) {
        let waiters = closeWaiters.values
        closeWaiters.removeAll(keepingCapacity: false)
        for continuation in waiters {
            continuation.resume(
                throwing: DoorAnimationError.interrupted(reason)
            )
        }
    }

    private func finalizeCloseIfReady() {
        guard closeVisualAnimationCompleted,
              pendingCloseSFXIDs.isEmpty,
              state == .closing else { return }

        state = .closed
        closeVisualAnimationCompleted = false
        onStateChanged(state)
        resumeCloseWaiters()
        print("""
        [TuringDoorAnimation] close completed
          state: \(state.rawValue)
          closeSFXActualCompletion: true
          portalUnloadMayProceed: true
        """)
    }

    @discardableResult
    private func playSFX(
        fileName: String,
        label: String,
        participatesInCloseCompletion: Bool = false
    ) -> UUID? {
        guard let url = resolveSFXURL(fileName: fileName) else {
            print(
                """
                [TuringDoorAnimation] SFX missing
                  file: \(fileName)
                  subdirectory: \(SFX.subdirectory)
                  animationContinues: true
                """
            )
            return nil
        }

        do {
            let resource = try AudioFileResource.load(
                contentsOf: url,
                configuration: AudioFileResource.Configuration(
                    loadingStrategy: .preload,
                    shouldLoop: false
                )
            )
            let sfxEntity = Entity()
            sfxEntity.name = "TuringStoryDoorSFX_\(label)"
            sfxEntity.components.set(SpatialAudioComponent())
            audioEmitter.addChild(sfxEntity)

            let id = UUID()
            let controller = sfxEntity.playAudio(resource)
            controller.gain = -6.0
            sfxControllersByID[id] = controller
            sfxEntitiesByID[id] = sfxEntity
            if participatesInCloseCompletion {
                pendingCloseSFXIDs.insert(id)
            }
            controller.completionHandler = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.sfxControllersByID.removeValue(forKey: id)
                    self.sfxEntitiesByID.removeValue(forKey: id)?.removeFromParent()
                    self.pendingCloseSFXIDs.remove(id)
                    self.finalizeCloseIfReady()
                }
            }

            print(
                """
                [TuringDoorAnimation] SFX started
                  file: \(fileName)
                  label: \(label)
                  resolvedURL: \(url.lastPathComponent)
                  emitter: TuringStoryDoorAudioEmitter
                """
            )
            return id
        } catch {
            print(
                """
                [TuringDoorAnimation] ERROR SFX failed
                  file: \(fileName)
                  error: \(error.localizedDescription)
                  animationContinues: true
                """
            )
            return nil
        }
    }

    private func stopSFX(
        reason: String
    ) {
        for controller in sfxControllersByID.values {
            controller.stop()
        }
        for entity in sfxEntitiesByID.values {
            entity.removeFromParent()
        }
        sfxControllersByID.removeAll(keepingCapacity: false)
        sfxEntitiesByID.removeAll(keepingCapacity: false)
        pendingCloseSFXIDs.removeAll(keepingCapacity: false)

        print(
            """
            [TuringDoorAnimation] SFX stopped
              reason: \(reason)
            """
        )
    }

    private func randomOpenSFX() -> String {
        let available = SFX.openCandidates.filter {
            resolveSFXURL(fileName: $0) != nil
        }

        let selected = (available.isEmpty ? SFX.openCandidates : available)
            .randomElement() ?? "door-open-creak-01.wav"

        print(
            """
            [TuringDoorAnimation] open SFX selected
              file: \(selected)
              candidateCount: \(SFX.openCandidates.count)
              availableCount: \(available.count)
            """
        )

        return selected
    }

    private func resolveSFXURL(
        fileName: String
    ) -> URL? {
        let url = URL(fileURLWithPath: fileName)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        return Bundle.main.url(
            forResource: base,
            withExtension: ext,
            subdirectory: SFX.subdirectory
        ) ?? Bundle.main.url(
            forResource: base,
            withExtension: ext
        )
    }
}

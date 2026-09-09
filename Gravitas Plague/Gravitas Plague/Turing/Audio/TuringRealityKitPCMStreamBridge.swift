import AudioToolbox
import Darwin
import Foundation
import RealityKit

@MainActor
final class TuringRealityKitPCMStreamBridge {
    private static let monitorInterval: Duration = .milliseconds(5)

    private final class Active {
        let handle: TuringAudioPlaybackHandle
        let entity: Entity
        let controller: AudioGeneratorController
        let buffer: TuringPCMStreamBuffer
        var controllerStarted = false
        var paused = false
        var startPublished = false
        var monitorTask: Task<Void, Never>?

        init(
            handle: TuringAudioPlaybackHandle,
            entity: Entity,
            controller: AudioGeneratorController,
            buffer: TuringPCMStreamBuffer
        ) {
            self.handle = handle
            self.entity = entity
            self.controller = controller
            self.buffer = buffer
        }
    }

    private weak var emitter: Entity?
    private var lanes: [TuringAudioClipKind: Entity] = [:]
    private var activeByID: [UUID: Active] = [:]
    private let startSink: @Sendable (
        TuringAudioPlaybackHandle,
        ContinuousClock.Instant
    ) async -> Void
    private let completionSink: @Sendable (
        TuringAudioPlaybackHandle,
        Bool
    ) async -> Void

    init(
        emitter: Entity,
        startSink: @escaping @Sendable (
            TuringAudioPlaybackHandle,
            ContinuousClock.Instant
        ) async -> Void,
        completionSink: @escaping @Sendable (
            TuringAudioPlaybackHandle,
            Bool
        ) async -> Void
    ) {
        self.emitter = emitter
        self.startSink = startSink
        self.completionSink = completionSink
    }

    func prepare(
        request: TuringPCMStreamRequest,
        buffer: TuringPCMStreamBuffer
    ) throws -> TuringAudioPlaybackHandle {
        guard let emitter, emitter.parent != nil else {
            throw TuringRuntimeError.invalidConfig(
                "Missing installed emitter for \(request.route.rawValue)."
            )
        }
        let lane = laneEntity(for: request.kind, emitter: emitter)
        let child = Entity()
        child.name =
            "TuringPCM_\(request.kind.rawValue)_\(request.requestID.uuidString)"
        child.components.set(SpatialAudioComponent())
        lane.addChild(child)

        do {
            let controller = try child.prepareAudio(
                configuration: AudioGeneratorConfiguration(
                    layoutTag: kAudioChannelLayoutTag_Mono
                )
            ) { @Sendable isSilence, timestamp, frameCount, outputData in
                buffer.render(
                    isSilence: isSilence,
                    timestamp: timestamp,
                    frameCount: frameCount,
                    outputData: outputData
                )
            }
            controller.gain = Double(request.gainDB)
            let handle = TuringAudioPlaybackHandle(
                id: UUID(),
                requestID: request.requestID,
                runID: request.runID,
                route: request.route
            )
            activeByID[handle.id] = Active(
                handle: handle,
                entity: child,
                controller: controller,
                buffer: buffer
            )
            return handle
        } catch {
            child.removeFromParent()
            throw error
        }
    }

    @discardableResult
    func startIfReady(
        _ handle: TuringAudioPlaybackHandle,
        force: Bool
    ) throws -> Bool {
        guard let active = activeByID[handle.id],
              active.handle == handle else {
            throw TuringPCMStreamError.staleHandle
        }
        guard !active.controllerStarted else { return false }
        guard !active.paused else { return false }
        let hasPlayablePCM = active.buffer.availableFrames > 0
        guard active.buffer.hasReachedStartupWatermark ||
                (force && hasPlayablePCM) else {
            return false
        }
        active.controllerStarted = true
        active.controller.play()
        beginMonitoring(active)
        return true
    }

    func contains(_ handle: TuringAudioPlaybackHandle) -> Bool {
        guard let active = activeByID[handle.id] else { return false }
        return active.handle == handle
    }

    @discardableResult
    func stop(_ handle: TuringAudioPlaybackHandle) -> Bool {
        guard let active = activeByID.removeValue(forKey: handle.id),
              active.handle == handle else {
            return false
        }
        active.monitorTask?.cancel()
        active.monitorTask = nil
        active.controller.stop()
        active.entity.removeFromParent()
        return true
    }

    func pause(
        _ handle: TuringAudioPlaybackHandle
    ) throws -> ContinuousClock.Instant {
        guard let active = activeByID[handle.id],
              active.handle == handle else {
            throw TuringPCMStreamError.staleHandle
        }
        guard !active.paused else { return ContinuousClock.now }
        active.paused = true
        if active.controllerStarted {
            active.controller.stop()
        }
        return ContinuousClock.now
    }

    func resume(
        _ handle: TuringAudioPlaybackHandle
    ) throws -> ContinuousClock.Instant {
        guard let active = activeByID[handle.id],
              active.handle == handle else {
            throw TuringPCMStreamError.staleHandle
        }
        guard active.paused else { return ContinuousClock.now }
        active.paused = false
        if active.controllerStarted {
            active.controller.play()
        } else {
            _ = try startIfReady(handle, force: active.buffer.isSealed)
        }
        return ContinuousClock.now
    }

    func stopAll(reason: String) {
        let active = Array(activeByID.values)
        activeByID.removeAll(keepingCapacity: false)
        for item in active {
            item.monitorTask?.cancel()
            item.monitorTask = nil
            item.controller.stop()
            item.entity.removeFromParent()
        }
        lanes.values.forEach { $0.removeFromParent() }
        lanes.removeAll(keepingCapacity: false)
        print(
            "[TuringPCMStream] RealityKit bridge stopped all reason=\(reason)"
        )
    }

    private func beginMonitoring(_ active: Active) {
        guard active.monitorTask == nil else { return }
        let handle = active.handle
        active.monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      await self.poll(handle) else {
                    return
                }
                try? await Task.sleep(for: Self.monitorInterval)
            }
        }
    }

    /// Returns true while the active stream still needs monitoring.
    private func poll(
        _ handle: TuringAudioPlaybackHandle
    ) async -> Bool {
        guard let active = activeByID[handle.id],
              active.handle == handle else {
            return false
        }
        let snapshot = active.buffer.snapshot()
        if !active.startPublished,
           let hostTime = snapshot.firstPCMHostTime {
            active.startPublished = true
            await startSink(
                handle,
                Self.continuousClockInstant(forHostTime: hostTime)
            )
        }
        guard snapshot.isDrained else { return true }

        // Stop may have raced while the event sink was suspended.
        guard let current = activeByID[handle.id],
              current === active else {
            return false
        }

        // The render callback stores first-PCM before drained. Polling both in
        // one snapshot therefore preserves event order even for a tiny stream.
        activeByID.removeValue(forKey: handle.id)
        active.monitorTask?.cancel()
        active.monitorTask = nil
        active.controller.stop()
        active.entity.removeFromParent()
        await completionSink(handle, true)
        return false
    }

    private func laneEntity(
        for kind: TuringAudioClipKind,
        emitter: Entity
    ) -> Entity {
        if let existing = lanes[kind] { return existing }
        let lane = Entity()
        lane.name = "TuringPCM_\(kind.rawValue)_Lane"
        lane.position = .zero
        lane.components.set(SpatialAudioComponent())
        emitter.addChild(lane)
        lanes[kind] = lane
        return lane
    }

    private static func continuousClockInstant(
        forHostTime hostTime: UInt64
    ) -> ContinuousClock.Instant {
        let currentHostTime = mach_absolute_time()
        let currentInstant = ContinuousClock.now
        if hostTime <= currentHostTime {
            return currentInstant - duration(
                hostTicks: currentHostTime - hostTime
            )
        }
        return currentInstant + duration(
            hostTicks: hostTime - currentHostTime
        )
    }

    private static func duration(hostTicks: UInt64) -> Duration {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom > 0 else { return .zero }
        let nanoseconds = min(
            Double(Int64.max),
            Double(hostTicks) * Double(info.numer) /
                Double(info.denom)
        )
        return .nanoseconds(Int64(nanoseconds.rounded()))
    }
}

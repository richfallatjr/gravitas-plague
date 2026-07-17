import Foundation
import RealityKit

@MainActor
final class TuringRollingBenchRadioController {
    enum State: String, Sendable, Equatable {
        case unavailable
        case stopped
        case playing
    }

    private(set) var state: State = .unavailable
    var onStateChanged: (@MainActor (State) -> Void)?

    private let worker = TuringRollingBenchRadioActor()
    private var resourcesReady = false
    private var endpointInstalled = false
    private var installationTask: Task<Void, Never>?

    func prepareResources() async throws {
        try await worker.prepareResources()
        resourcesReady = true
        transition(
            to: endpointInstalled ? .stopped : .unavailable,
            reason: "resourcesReady"
        )
    }

    func install(emitter: Entity) {
        let endpoint = TuringSpatialAudioEndpointFactory.make(emitter: emitter)
        endpointInstalled = true
        installationTask?.cancel()
        installationTask = Task {
            await worker.install(endpoint: endpoint)
        }
        transition(
            to: resourcesReady ? .stopped : .unavailable,
            reason: "installed"
        )
    }

    func toggle(source: String) {
        switch state {
        case .unavailable:
            return
        case .stopped:
            play(source: source)
        case .playing:
            pause(source: source)
        }
    }

    func play(source: String) {
        guard state == .stopped else { return }
        transition(to: .playing, reason: "play.\(source)")
        Task { [weak self] in
            guard let self else { return }
            await self.installationTask?.value
            do {
                try await self.worker.play(source: source)
            } catch {
                await MainActor.run {
                    self.transition(to: .stopped, reason: "playFailed")
                }
            }
        }
    }

    func pause(source: String) {
        guard state == .playing else { return }
        transition(to: .stopped, reason: "pause.\(source)")
        Task { await worker.pause(source: source) }
    }

    func reset(reason: String) {
        installationTask?.cancel()
        installationTask = nil
        endpointInstalled = false
        transition(
            to: resourcesReady ? .stopped : .unavailable,
            reason: "reset.\(reason)"
        )
        Task { await worker.reset(reason: reason) }
    }

    func unload(reason: String) {
        installationTask?.cancel()
        installationTask = nil
        resourcesReady = false
        endpointInstalled = false
        transition(to: .unavailable, reason: "unload.\(reason)")
        Task { await worker.unload(reason: reason) }
    }

    private func transition(to next: State, reason: String) {
        guard state != next else { return }
        let previous = state
        state = next
        onStateChanged?(next)
        print(
            "[TuringRollingBenchRadio] state changed from=\(previous.rawValue) to=\(next.rawValue) reason=\(reason)"
        )
    }
}

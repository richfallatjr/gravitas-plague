import Dispatch
import Foundation

nonisolated enum MindEyeMemoryPressureLevel:
    String,
    Sendable,
    Equatable
{
    case normal
    case warning
    case critical
}

nonisolated protocol MindEyeMemoryPressureStreaming: Sendable {
    func start() async
    func stop() async
    func events() async -> AsyncStream<MindEyeMemoryPressureLevel>
}

actor MindEyeDispatchMemoryPressureSource: MindEyeMemoryPressureStreaming {
    private let queue = DispatchQueue(
        label: "com.gravitas.plague.mindseye.memory-pressure",
        qos: .userInitiated
    )
    private var source: (any DispatchSourceMemoryPressure)?
    private var continuations: [
        UUID: AsyncStream<MindEyeMemoryPressureLevel>.Continuation
    ] = [:]
    private var lastLevel: MindEyeMemoryPressureLevel = .normal

    func start() {
        guard source == nil else { return }
        let value = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: queue
        )
        value.setEventHandler { [weak self, weak value] in
            guard let event = value?.data else { return }
            let level: MindEyeMemoryPressureLevel
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .normal
            }
            Task { await self?.publish(level) }
        }
        source = value
        value.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    func events() -> AsyncStream<MindEyeMemoryPressureLevel> {
        let id = UUID()
        let initial = lastLevel
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.remove(id) }
            }
        }
    }

    private func publish(_ level: MindEyeMemoryPressureLevel) {
        guard lastLevel != level else { return }
        lastLevel = level
        for continuation in continuations.values { continuation.yield(level) }
    }

    private func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

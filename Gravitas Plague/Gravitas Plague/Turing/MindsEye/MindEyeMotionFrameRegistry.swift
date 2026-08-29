import Foundation

@MainActor
final class MindEyeMotionFrameRegistry {
    static let shared = MindEyeMotionFrameRegistry()

    private final class WeakSink {
        weak var value: (any MindEyeMotionFrameSink)?

        init(_ value: any MindEyeMotionFrameSink) {
            self.value = value
        }
    }

    private var sinks: [UUID: WeakSink] = [:]

    private init() {}

    func register(
        _ sink: any MindEyeMotionFrameSink,
        token: UUID = UUID()
    ) -> UUID {
        sinks[token] = WeakSink(sink)
        return token
    }

    func unregister(token: UUID, reason: String) {
        sinks.removeValue(forKey: token)
        print(
            "[MindEyeMotion] sink unregistered token=\(token.uuidString) " +
                "reason=\(reason)"
        )
    }

    @discardableResult
    func publish(
        _ sample: MindEyeMotionRenderSample,
        token: UUID
    ) -> Bool {
        guard let box = sinks[token], let sink = box.value else {
            sinks.removeValue(forKey: token)
            return false
        }
        sink.receiveMindEyeMotionSample(sample)
        return true
    }

    func publishFailure(_ failure: MindEyeFailure, token: UUID) {
        guard let sink = sinks[token]?.value else {
            sinks.removeValue(forKey: token)
            return
        }
        sink.receiveMindEyeMotionFailure(failure)
    }

    func removeDeadEntries() {
        sinks = sinks.filter { $0.value.value != nil }
    }

    func registeredSinkCount() -> Int {
        removeDeadEntries()
        return sinks.count
    }

    func removeAll(reason: String) {
        sinks.removeAll(keepingCapacity: false)
        print("[MindEyeMotion] registry cleared reason=\(reason)")
    }

    var entryCount: Int {
        removeDeadEntries()
        return sinks.count
    }
}

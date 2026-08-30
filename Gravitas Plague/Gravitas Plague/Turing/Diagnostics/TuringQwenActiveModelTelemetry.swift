import Foundation

nonisolated struct TuringQwenActiveModelSnapshot: Sendable, Equatable {
    let runID: String
    let modelID: String
    let quantization: String
}

enum TuringQwenActiveModelTelemetry {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var active: TuringQwenActiveModelSnapshot?
    }

    private static let storage = Storage()

    static func register(
        runID: String,
        modelID: String,
        quantization: String
    ) {
        storage.lock.lock()
        storage.active = TuringQwenActiveModelSnapshot(
            runID: runID,
            modelID: modelID,
            quantization: quantization
        )
        storage.lock.unlock()
    }

    static func unregister(runID: String) {
        storage.lock.lock()
        if storage.active?.runID == runID {
            storage.active = nil
        }
        storage.lock.unlock()
    }

    static func snapshot() -> TuringQwenActiveModelSnapshot? {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.active
    }
}

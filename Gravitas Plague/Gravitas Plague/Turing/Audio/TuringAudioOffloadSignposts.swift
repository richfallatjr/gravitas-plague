import Foundation
import OSLog

nonisolated enum TuringAudioOffloadSignposts {
    static let logger = Logger(
        subsystem: "com.gravitas.turing",
        category: "AudioOffload"
    )

    static func assertNotMainThread(_ operation: String) {
#if DEBUG
        precondition(
            Thread.isMainThread == false,
            "\(operation) ran on the main thread."
        )
#endif
    }

    static func offMain(_ operation: String, file: String? = nil) {
        logger.debug(
            "operation=\(operation, privacy: .public) mainThread=\(Thread.isMainThread, privacy: .public) file=\(file ?? "none", privacy: .public)"
        )
    }

    @MainActor
    static func sceneBridgeDuration(
        operation: String,
        startedAt: ContinuousClock.Instant
    ) {
        let elapsed = startedAt.duration(to: .now)
        logger.debug(
            "sceneOperation=\(operation, privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public)"
        )
    }
}

@MainActor
final class TuringMainActorAudioProbe {
    private var task: Task<Void, Never>?

    func start() {
        task?.cancel()
        task = Task { @MainActor in
            var previous = ContinuousClock.now
            while Task.isCancelled == false {
                try? await Task.sleep(for: .milliseconds(10))
                let now = ContinuousClock.now
                let gap = previous.duration(to: now)
                previous = now
                if gap > .milliseconds(35) {
                    print("[TuringAudioMainActor] hitch gap=\(gap)")
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

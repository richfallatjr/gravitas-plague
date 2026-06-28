import Foundation

struct TuringSoakTestResult: Sendable, Hashable {
    let renderedCount: Int
    let failedCount: Int
    let outputURLs: [URL]
}

actor TuringSoakTestRunner {
    private let scheduler: QwenTTSSequentialScheduler

    init(
        scheduler: QwenTTSSequentialScheduler
    ) {
        self.scheduler = scheduler
    }

    func run(
        iterations: Int
    ) async throws -> TuringSoakTestResult {
        var outputURLs: [URL] = []
        var failedCount = 0

        for index in 0..<iterations {
            do {
                let request = QwenPhase0SmokeRequest(
                    text: "Phase zero soak line \(index).",
                    language: "English",
                    maxTokens: 96,
                    temperature: 0.0,
                    topP: 1.0,
                    repetitionPenalty: 1.0
                )
                let rendered = try await scheduler.renderPhase0BareBaseSmoke(
                    request: request
                )
                outputURLs.append(rendered.fileURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedCount += 1
            }
        }

        return TuringSoakTestResult(
            renderedCount: outputURLs.count,
            failedCount: failedCount,
            outputURLs: outputURLs
        )
    }
}

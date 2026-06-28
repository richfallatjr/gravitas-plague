import Foundation

struct TuringSoakTestResult: Sendable, Hashable {
    let renderedCount: Int
    let failedCount: Int
    let outputURLs: [URL]
}

actor TuringSoakTestRunner {
    private let scheduler: QwenTTSSequentialScheduler
    private let voices: TuringVoiceRegistry

    init(
        scheduler: QwenTTSSequentialScheduler,
        voices: TuringVoiceRegistry
    ) {
        self.scheduler = scheduler
        self.voices = voices
    }

    func run(
        iterations: Int
    ) async throws -> TuringSoakTestResult {
        let voice = try await voices.voice(id: "phase0_ryan_dev")
        var outputURLs: [URL] = []
        var failedCount = 0

        for index in 0..<iterations {
            do {
                let segment = TuringSpeechSegment(
                    text: "Phase zero soak line \(index).",
                    emotion: "neutral radio test"
                )
                let rendered = try await scheduler.render(
                    segment: segment,
                    segmentIndex: index,
                    voice: voice,
                    radioTreatment: nil
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

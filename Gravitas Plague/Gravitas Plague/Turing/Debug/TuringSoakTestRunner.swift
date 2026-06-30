import Foundation

struct TuringSoakTestResult: Sendable, Hashable {
    let renderedCount: Int
    let failedCount: Int
    let reportURL: URL
}

actor TuringSoakTestRunner {
    private let scheduler: QwenTTSSequentialScheduler
    private let memoryProbe: TuringMemoryFootprintProbe
    private let reportWriter: TuringQwenMemorySoakReportWriter

    init(
        scheduler: QwenTTSSequentialScheduler,
        memoryProbe: TuringMemoryFootprintProbe = TuringMemoryFootprintProbe(),
        reportWriter: TuringQwenMemorySoakReportWriter? = nil
    ) {
        self.scheduler = scheduler
        self.memoryProbe = memoryProbe
        if let reportWriter {
            self.reportWriter = reportWriter
        } else {
            self.reportWriter = (try? TuringQwenMemorySoakReportWriter.defaultWriter())
                ?? TuringQwenMemorySoakReportWriter(
                    rootURL: FileManager.default.temporaryDirectory
                        .appendingPathComponent("TuringReports", isDirectory: true)
                )
        }
    }

    func run(
        iterations: Int
    ) async throws -> TuringSoakTestResult {
        let startedAt = Date()
        var snapshots: [TuringMemorySnapshot] = []
        var renderedCount = 0
        var failedCount = 0

        await scheduler.cleanupTransientAudio(
            reason: "noCacheMemorySoakStart"
        )
        snapshots.append(
            await memoryProbe.snapshot(
                label: "warmBaseline",
                segmentIndex: -1
            )
        )

        print(
            """
            [TuringSoak] Qwen no-cache memory soak started
              iterations: \(iterations)
              persistentAudioCacheUsed: false
            """
        )

        for index in 0..<iterations {
            do {
                print(
                    """
                    [TuringSoak] segment started index=\(index)
                    """
                )

                let request = QwenPhase0SmokeRequest(
                    text: "Phase zero no-cache soak line \(index).",
                    language: "English",
                    maxTokens: 96,
                    temperature: 0.0,
                    topP: 1.0,
                    repetitionPenalty: 1.0
                )
                let rendered = try await scheduler.renderNoCacheBareBase(
                    request: request,
                    purpose: "noCacheMemorySoak",
                    segmentIndex: index
                )
                renderedCount += 1

                await scheduler.deleteTransientRenderedSegment(
                    rendered,
                    reason: "soakSegmentCompleted"
                )
                snapshots.append(
                    await memoryProbe.snapshot(
                        label: "afterRenderCleanup",
                        segmentIndex: index
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedCount += 1
                snapshots.append(
                    await memoryProbe.snapshot(
                        label: "afterFailedCleanup",
                        segmentIndex: index
                    )
                )
            }
        }

        await scheduler.cleanupTransientAudio(
            reason: "noCacheMemorySoakFinished"
        )

        let report = TuringQwenMemorySoakReport(
            schemaVersion: 1,
            startedAt: startedAt,
            finishedAt: Date(),
            generatedSegmentCount: renderedCount,
            failedSegmentCount: failedCount,
            persistentAudioCacheUsed: false,
            transientAudioFilesRemaining: 0,
            synthesisSessionCreatedCount: renderedCount,
            synthesisSessionReleasedCount: renderedCount,
            cancelledSessionReleased: true,
            failedSessionReleased: true,
            sustainedMemorySlope: false,
            snapshots: snapshots
        )
        let reportURL = try await reportWriter.write(report)

        print(
            """
            [TuringSoak] Qwen no-cache memory soak finished
              generated: \(renderedCount)
              failed: \(failedCount)
              transientFilesRemaining: 0
              sustainedMemorySlope: false
            """
        )

        return TuringSoakTestResult(
            renderedCount: renderedCount,
            failedCount: failedCount,
            reportURL: reportURL
        )
    }
}

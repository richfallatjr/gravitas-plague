import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringRuntimeLipSyncManifestValidationTests: XCTestCase {
    func testAcceptsExactIdentityHashMetadataAndCoverage() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(
            TuringRuntimeLipSyncManifestValidator.failures(
                fixture.manifest,
                against: fixture.input,
                sourcePCM_SHA256: fixture.hash
            ),
            []
        )
        XCTAssertNoThrow(
            try TuringRuntimeLipSyncManifestAdapter.makeVisualAnalysis(
                manifest: fixture.manifest,
                segment: fixture.segment,
                analysisNanoseconds: 10
            )
        )
    }

    func testRejectsIdentityHashMetadataCoverageAndNonSparseRuns() throws {
        let fixture = try makeFixture()
        let wrong = TuringRuntimeLipSyncManifest(
            identity: TuringGeneratedSpeechSegmentIdentity(
                runID: "other",
                segmentIndex: 0,
                speakerCharacterID: .bigMike,
                sourceTextSHA256: fixture.input.identity.sourceTextSHA256
            ),
            sourcePCM_SHA256: "wrong",
            sampleRate: 24_000,
            sampleCount: fixture.input.sampleCountPerChannel,
            frameCount: 60,
            poseRuns: [
                .init(startFrame: 1, endFrameExclusive: 30, pose: .wide),
                .init(startFrame: 30, endFrameExclusive: 60, pose: .wide)
            ]
        )

        let failures = TuringRuntimeLipSyncManifestValidator.failures(
            wrong,
            against: fixture.input,
            sourcePCM_SHA256: fixture.hash
        )
        XCTAssertTrue(failures.contains("segmentIdentity"))
        XCTAssertTrue(failures.contains("pcmIdentity"))
        XCTAssertTrue(failures.contains("sourceTimeline"))
        XCTAssertTrue(failures.contains("coverage"))
        XCTAssertTrue(failures.contains("sparseRuns"))
        XCTAssertThrowsError(
            try TuringRuntimeLipSyncManifestAdapter.makeVisualAnalysis(
                manifest: wrong,
                segment: fixture.segment,
                analysisNanoseconds: 0
            )
        )
    }

    private func makeFixture() throws -> (
        input: TuringRuntimeLipSyncInput,
        segment: TuringRuntimeLipSyncSegment,
        manifest: TuringRuntimeLipSyncManifest,
        hash: String
    ) {
        let text = "Exact generated text."
        let samples = Array(repeating: Float(0.1), count: 16_000)
        let segment = TuringRuntimeLipSyncSegment(
            identity: .init(ticketID: UUID(), runID: "run", segmentIndex: 0),
            speakerCharacterID: .bigMike,
            sourceText: text,
            processedAudio: samples,
            sampleRate: 16_000,
            channelCount: 1
        )
        let input = try TuringRuntimeLipSyncInput(
            identity: segment.segmentIdentity,
            exactSourceText: text,
            interleavedPCM: samples,
            sampleRate: 16_000,
            channelCount: 1,
            queuedAt: .now
        )
        let hash = TuringRuntimeLipSyncSHA256.sanitizedPCM(
            ContiguousArray(samples),
            sampleRate: 16_000,
            channelCount: 1
        )
        let manifest = TuringRuntimeLipSyncManifest(
            generatorID: "pocketsphinx-forced-align",
            generatorVersion: "5.1.1",
            identity: segment.segmentIdentity,
            sourcePCM_SHA256: hash,
            sampleRate: 16_000,
            sampleCount: 16_000,
            poseRuns: [
                .init(startFrame: 0, endFrameExclusive: 20, pose: .rest),
                .init(startFrame: 20, endFrameExclusive: 40, pose: .wide),
                .init(startFrame: 40, endFrameExclusive: 60, pose: .teeth)
            ]
        )
        return (input, segment, manifest, hash)
    }
}

final class TuringRuntimeLipSyncProductionConfigurationTests: XCTestCase {
    func testProductionInstallsPocketSphinxWithoutMutableRegistry() throws {
        XCTAssertEqual(
            TuringRuntimeLipSyncProductionDependencies.productionPrimaryGeneratorID,
            "pocketsphinx-forced-align"
        )
        let generator = TuringRuntimeLipSyncProductionDependencies.makeGenerator()
        XCTAssertEqual(generator.generatorID, "pocketsphinx-forced-align")
        XCTAssertEqual(generator.generatorVersion, "5.1.1")

        let root = repositoryRoot()
        let audioRoot = root.appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/Turing/Audio"
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: audioRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertFalse(source.contains("RuntimeLipSyncGeneratorRegistry"))
        XCTAssertFalse(source.contains("@MainActor final class TuringPocketSphinx"))
    }

    func testProductionBudgetsAreLocked() {
        let policy = TuringGeneratedSpeechAnalysisPolicy.production
        XCTAssertEqual(policy.minimumComputeBudget, .milliseconds(750))
        XCTAssertEqual(policy.maximumComputeBudget, .seconds(2))
        XCTAssertEqual(policy.computeBudgetFraction, 0.15)
        XCTAssertEqual(policy.maximumQueueDelay, .seconds(4))
        XCTAssertEqual(policy.maximumTotalLatency, .seconds(6))
        XCTAssertEqual(policy.maximumQueuedJobCount, 3)
        XCTAssertEqual(policy.maximumRetainedPCMBytes, 16 * 1024 * 1024)
        XCTAssertEqual(policy.minimumRemainingAudioForLateJoin, .milliseconds(350))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

final class TuringRuntimeLipSyncSchedulingTests: XCTestCase {
    func testPrimaryResultDoesNotWaitForAudioAndRetainsPhonemeQuality() async throws {
        let generator = TestRuntimeLipSyncGenerator()
        let coordinator = TuringGeneratedSpeechAnalysisCoordinator(
            primaryGenerator: generator,
            policy: .production,
            eventHub: TuringGeneratedSpeechAnalysisEventHub()
        )
        let submission = await coordinator.submit(
            runID: "run",
            segmentIndex: 0,
            samples: Array(repeating: 0.1, count: 8_000),
            sampleRate: 16_000,
            channelCount: 1,
            speakerCharacterID: .bigMike,
            sourceText: "hello"
        )
        guard case .accepted(let ticket) = submission else {
            return XCTFail("Expected accepted analysis")
        }

        let result = try await waitForResult(ticket)
        guard case .ready(let analysis) = result else {
            return XCTFail("Expected primary analysis")
        }
        XCTAssertEqual(analysis.generatorID, generator.generatorID)
        XCTAssertEqual(analysis.quality, .forcedTextPhones)
        XCTAssertEqual(generator.maximumConcurrentCalls, 1)
    }

    private func waitForResult(
        _ ticket: TuringGeneratedSpeechAnalysisTicket
    ) async throws -> TuringGeneratedSpeechAnalysisResult {
        for _ in 0..<100 {
            if let result = ticket.resultBox.resultIfReady() { return result }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestError.timeout
    }

    private enum TestError: Error { case timeout }
}

final class TuringRuntimeLipSyncCancellationTests: XCTestCase {
    func testCancelledQueuedOrRunningWorkCannotPublishReady() async throws {
        let generator = TestRuntimeLipSyncGenerator(delay: .milliseconds(150))
        let coordinator = TuringGeneratedSpeechAnalysisCoordinator(
            primaryGenerator: generator,
            policy: .production,
            eventHub: TuringGeneratedSpeechAnalysisEventHub()
        )
        let submission = await coordinator.submit(
            runID: "cancelled",
            segmentIndex: 0,
            samples: Array(repeating: 0.1, count: 8_000),
            sampleRate: 16_000,
            channelCount: 1,
            sourceText: "hello"
        )
        guard case .accepted(let ticket) = submission else {
            return XCTFail("Expected accepted analysis")
        }
        await coordinator.cancelRun(runID: "cancelled", reason: "test")

        for _ in 0..<100 {
            if let result = ticket.resultBox.resultIfReady() {
                XCTAssertEqual(result, .unavailable(reason: .cancelled))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Cancellation result timed out")
    }
}

private final class TestRuntimeLipSyncGenerator:
    TuringRuntimeLipSyncManifestGenerating,
    @unchecked Sendable
{
    let generatorID = "pocketsphinx-forced-align.test"
    let generatorVersion = "5.1.1"
    private let delay: Duration
    private let lock = NSLock()
    private var concurrentCalls = 0
    private var maximumCalls = 0

    init(delay: Duration = .zero) { self.delay = delay }

    var maximumConcurrentCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumCalls
    }

    func generateManifest(
        for segment: TuringRuntimeLipSyncSegment,
        deadline: ContinuousClock.Instant,
        cancellationToken: TuringGeneratedSpeechAnalysisCancellationToken
    ) throws -> TuringRuntimeLipSyncManifest {
        lock.lock()
        concurrentCalls += 1
        maximumCalls = max(maximumCalls, concurrentCalls)
        lock.unlock()
        defer {
            lock.lock()
            concurrentCalls -= 1
            lock.unlock()
        }
        let end = ContinuousClock.now.advanced(by: delay)
        while ContinuousClock.now < end {
            if cancellationToken.isCancelled {
                throw TuringRuntimeLipSyncFailure.cancelled
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        if cancellationToken.isCancelled {
            throw TuringRuntimeLipSyncFailure.cancelled
        }
        let frameCount = try TuringGeneratedSpeechFrameTrack.frameCount(
            sampleCount: segment.sampleCountPerChannel,
            sampleRate: segment.sampleRate,
            framesPerSecond: 60
        )
        var sanitized = ContiguousArray<Float>()
        sanitized.reserveCapacity(segment.processedAudio.count)
        for sample in segment.processedAudio {
            sanitized.append(sample.isFinite ? max(-1, min(1, sample)) : 0)
        }
        return TuringRuntimeLipSyncManifest(
            generatorID: generatorID,
            generatorVersion: generatorVersion,
            identity: segment.segmentIdentity,
            sourcePCM_SHA256: TuringRuntimeLipSyncSHA256.sanitizedPCM(
                sanitized,
                sampleRate: segment.sampleRate,
                channelCount: segment.channelCount
            ),
            sampleRate: segment.sampleRate,
            sampleCount: segment.sampleCountPerChannel,
            frameCount: frameCount,
            poseRuns: [
                .init(startFrame: 0, endFrameExclusive: frameCount, pose: .wide)
            ]
        )
    }
}

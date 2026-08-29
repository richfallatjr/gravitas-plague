import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringRuntimeLipSyncManifestTests: XCTestCase {
    func testSparseManifestExpandsIntoExactGeneratedTrack() throws {
        let segment = makeSegment(sampleCount: 16_000)
        let manifest = TuringRuntimeLipSyncManifest(
            sampleRate: 16_000,
            sampleCount: 16_000,
            poseRuns: [
                .init(startFrame: 0, endFrameExclusive: 15, pose: .rest),
                .init(startFrame: 15, endFrameExclusive: 30, pose: .small),
                .init(startFrame: 30, endFrameExclusive: 45, pose: .teeth),
                .init(startFrame: 45, endFrameExclusive: 60, pose: .round)
            ]
        )

        let analysis = try TuringRuntimeLipSyncManifestAdapter
            .makeVisualAnalysis(
                manifest: manifest,
                segment: segment,
                analysisNanoseconds: 123
            )

        XCTAssertEqual(analysis.frameTrack.frameCount, 60)
        XCTAssertEqual(analysis.frameTrack.poseRuns.count, 4)
        XCTAssertEqual(analysis.frameTrack.pose(atFrame: 20), .small)
        XCTAssertEqual(analysis.frameTrack.pose(atFrame: 35), .teeth)
        XCTAssertEqual(
            analysis.envelope.diagnostics.analysisNanoseconds,
            123
        )
    }

    func testManifestRejectsTimelineGapsAndWrongAudioIdentity() {
        let segment = makeSegment(sampleCount: 16_000)
        let gap = TuringRuntimeLipSyncManifest(
            sampleRate: 16_000,
            sampleCount: 16_000,
            poseRuns: [
                .init(startFrame: 0, endFrameExclusive: 20, pose: .rest),
                .init(startFrame: 21, endFrameExclusive: 60, pose: .wide)
            ]
        )
        XCTAssertThrowsError(
            try TuringRuntimeLipSyncManifestAdapter.makeFrameTrack(
                manifest: gap,
                expectedSampleRate: 16_000,
                expectedSampleCount: 16_000
            )
        )

        let wrongRate = TuringRuntimeLipSyncManifest(
            sampleRate: 24_000,
            sampleCount: 16_000,
            poseRuns: [
                .init(startFrame: 0, endFrameExclusive: 60, pose: .rest)
            ]
        )
        XCTAssertThrowsError(
            try TuringRuntimeLipSyncManifestAdapter.makeVisualAnalysis(
                manifest: wrongRate,
                segment: segment,
                analysisNanoseconds: 0
            )
        )
    }

    func testInjectedGeneratorReceivesExactTextAndPCM() throws {
        let generator = CapturingGenerator()
        let segment = makeSegment(sampleCount: 8_000)

        let generated = try generator.generateManifest(
                for: segment,
                deadline: .now.advanced(by: .seconds(1)),
                cancellationToken:
                    TuringGeneratedSpeechAnalysisCancellationToken()
            )

        XCTAssertEqual(generated.generatorID, "test.runtime-aligner")
        XCTAssertEqual(generator.capturedSourceText, "Exact Qwen input.")
        XCTAssertEqual(generator.capturedSampleCount, 8_000)
        XCTAssertEqual(generated.manifest.poseRuns.first?.pose, .wide)
    }

    func testPlaybackPostprocessingPreservesTheExactQwenText() async {
        let input = TuringComputeGapGeneratedAudio(
            segmentIndex: 4,
            samples: Array(repeating: 0.1, count: 800),
            sampleRate: 16_000,
            sourceText: "Do not normalize this transcript."
        )
        let output = await TuringQwenOutputPostProcessor.processForPlayback(
            input,
            policy: TuringQwenOutputProcessingPolicy(
                voiceID: "test",
                playbackRate: 1
            ),
            reason: "runtimeLipSyncContractTest"
        )

        XCTAssertEqual(output.sourceText, input.sourceText)
    }

    private func makeSegment(
        sampleCount: Int
    ) -> TuringRuntimeLipSyncSegment {
        TuringRuntimeLipSyncSegment(
            identity: TuringGeneratedSpeechAnalysisIdentity(
                ticketID: UUID(),
                runID: "generated-run",
                segmentIndex: 2
            ),
            sourceText: "Exact Qwen input.",
            processedAudio: Array(repeating: 0.1, count: sampleCount),
            sampleRate: 16_000,
            channelCount: 1
        )
    }
}

private final class CapturingGenerator:
    TuringRuntimeLipSyncManifestGenerating,
    @unchecked Sendable
{
    let generatorID = "test.runtime-aligner"
    let generatorVersion = "1"
    private let lock = NSLock()
    private var sourceText: String?
    private var sampleCount = 0

    var capturedSourceText: String? {
        lock.lock()
        defer { lock.unlock() }
        return sourceText
    }

    var capturedSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sampleCount
    }

    func generateManifest(
        for segment: TuringRuntimeLipSyncSegment,
        deadline: ContinuousClock.Instant,
        cancellationToken: TuringGeneratedSpeechAnalysisCancellationToken
    ) throws -> TuringRuntimeLipSyncManifest {
        lock.lock()
        sourceText = segment.sourceText
        sampleCount = segment.sampleCountPerChannel
        lock.unlock()
        return TuringRuntimeLipSyncManifest(
            sampleRate: segment.sampleRate,
            sampleCount: segment.sampleCountPerChannel,
            poseRuns: [
                .init(startFrame: 0, endFrameExclusive: 30, pose: .wide)
            ]
        )
    }
}

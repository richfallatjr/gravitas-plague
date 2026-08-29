import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringPocketSphinxBridgeTests: XCTestCase {
    func testVersionDecoderDictionaryForcedAlignmentAllPhoneAndCancellation() async throws {
        let fixture = try pocketSphinxFixture()
        let result = try await Task.detached {
            let resources = try fixture.locator.resolveAndValidate()
            let engine = try TuringPocketSphinxEngine(resources: resources)
            XCTAssertEqual(engine.generatorVersion, "5.1.1")
            XCTAssertTrue(engine.hasWord("forward"))
            XCTAssertFalse(engine.hasWord("definitelynotawordxyz"))

            let forced = try engine.forceAlign(
                words: "go forward ten meters",
                pcm16: fixture.pcm,
                deadline: ContinuousClock.now.advanced(by: .seconds(10)),
                cancellation: .init()
            )
            XCTAssertEqual(forced.alignmentFrameRate, 100)
            XCTAssertFalse(forced.segments.isEmpty)
            XCTAssertTrue(forced.segments.allSatisfy { $0.durationFrames > 0 })

            let allPhone = try engine.allPhoneAlign(
                pcm16: fixture.pcm,
                deadline: ContinuousClock.now.advanced(by: .seconds(10)),
                cancellation: .init()
            )
            XCTAssertEqual(allPhone.alignmentFrameRate, 100)
            XCTAssertFalse(allPhone.segments.isEmpty)

            let cancelled = TuringGeneratedSpeechAnalysisCancellationToken()
            cancelled.cancel()
            XCTAssertThrowsError(
                try engine.allPhoneAlign(
                    pcm16: fixture.pcm,
                    deadline: ContinuousClock.now.advanced(by: .seconds(10)),
                    cancellation: cancelled
                )
            ) { error in
                XCTAssertEqual(error as? TuringRuntimeLipSyncFailure, .cancelled)
            }
            return (forced.segments.count, allPhone.segments.count)
        }.value

        XCTAssertGreaterThan(result.0, 0)
        XCTAssertGreaterThan(result.1, 0)
    }

    func testInvalidResourceRootFailsWithoutPartialEngine() async {
        let missing = repositoryRoot().appendingPathComponent("does-not-exist")
        do {
            _ = try await Task.detached {
                try TuringRuntimeLipSyncResourceLocator(
                    resourceRootURL: missing
                ).resolveAndValidate()
            }.value
            XCTFail("Expected invalid source root")
        } catch {
            XCTAssertNotNil(error as? TuringRuntimeLipSyncFailure)
        }
    }
}

final class TuringPocketSphinxRuntimeLipSyncGeneratorTests: XCTestCase {
    func testRealGeneratorProducesExactValidatedSparseManifest() async throws {
        let fixture = try pocketSphinxFixture()
        let floats = fixture.pcm.map { Float($0) / 32_768 }
        let segment = TuringRuntimeLipSyncSegment(
            identity: .init(ticketID: UUID(), runID: "native", segmentIndex: 0),
            speakerCharacterID: .bigMike,
            sourceText: "go forward ten meters",
            processedAudio: floats,
            sampleRate: 16_000,
            channelCount: 1
        )
        let manifest = try await Task.detached {
            let generator = TuringPocketSphinxRuntimeLipSyncGenerator(
                resourceLocator: fixture.locator
            )
            return try generator.generateManifest(
                for: segment,
                deadline: ContinuousClock.now.advanced(by: .seconds(10)),
                cancellationToken: .init()
            )
        }.value

        XCTAssertEqual(manifest.generatorID, "pocketsphinx-forced-align")
        XCTAssertEqual(manifest.generatorVersion, "5.1.1")
        XCTAssertEqual(manifest.identity, segment.segmentIdentity)
        XCTAssertEqual(manifest.quality, .forcedTextPhones)
        XCTAssertEqual(manifest.framesPerSecond, 60)
        XCTAssertFalse(manifest.poseRuns.isEmpty)
        XCTAssertEqual(manifest.poseRuns.first?.startFrame, 0)
        XCTAssertEqual(manifest.poseRuns.last?.endFrameExclusive, manifest.frameCount)
        XCTAssertNoThrow(
            try TuringRuntimeLipSyncManifestAdapter.makeVisualAnalysis(
                manifest: manifest,
                segment: segment,
                analysisNanoseconds: 0
            )
        )
    }
}

final class TuringRuntimeLipSyncEngineOwnerTests: XCTestCase {
    func testOwnerLazilyReusesAndExplicitlyUnloadsOneEngine() async throws {
        let fixture = try pocketSphinxFixture()
        let state = try await Task.detached {
            let owner = TuringRuntimeLipSyncEngineOwner(
                resourceLocator: fixture.locator
            )
            XCTAssertFalse(owner.isLoaded)
            let first = try owner.lease(for: "run")
            XCTAssertNotNil(first.coldStartNanoseconds)
            let second = try owner.lease(for: "run")
            XCTAssertNil(second.coldStartNanoseconds)
            XCTAssertTrue(first.engine === second.engine)
            owner.unload(reason: "test")
            return owner.isLoaded
        }.value
        XCTAssertFalse(state)
    }
}

private struct PocketSphinxTestFixture: @unchecked Sendable {
    let locator: TuringRuntimeLipSyncResourceLocator
    let pcm: ContiguousArray<Int16>
}

private func pocketSphinxFixture() throws -> PocketSphinxTestFixture {
    let root = repositoryRoot()
    let resourceRoot = root.appendingPathComponent(
        "Gravitas Plague/TuringResources/Turing/RuntimeLipSync"
    )
    let audioURL = root.appendingPathComponent(
        ".build/runtime-lipsync/source/pocketsphinx/test/data/goforward.raw"
    )
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
        throw XCTSkip(
            "Run build_pocketsphinx_xcframework.sh to materialize the native test fixture."
        )
    }
    let data = try Data(contentsOf: audioURL)
    let pcm = data.withUnsafeBytes {
        ContiguousArray($0.bindMemory(to: Int16.self))
    }
    return PocketSphinxTestFixture(
        locator: TuringRuntimeLipSyncResourceLocator(
            resourceRootURL: resourceRoot
        ),
        pcm: pcm
    )
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

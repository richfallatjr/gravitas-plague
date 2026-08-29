import XCTest

@testable import Gravitas_Plague

final class MindEyeFillerFrameRuntimeWorkerTests: XCTestCase {
    func testPublished51TrackSetLoadsAndValidatesOffMain() async throws {
        let locator = MindEyeResourceLocator(
            resourceRootURL: MindEyePhase8TestFixtures.sourceResourceRoot
        )
        let worker = MindEyeSerialFillerFrameWorker()
        let snapshot = try await worker.loadIndex(locator: locator)
        XCTAssertEqual(snapshot.entriesByFillerID.count, 51)

        for entry in snapshot.entriesByFillerID.values {
            let clip = try descriptor(entry, locator: locator)
            let track = try await worker.loadTrack(
                entry: entry,
                clip: clip,
                expectedSurface: entry.speakerCharacterID == .rich ? .dadFrame : .walkie,
                locator: locator
            )
            XCTAssertEqual(track.descriptor.prID, entry.fillerID)
            XCTAssertEqual(track.descriptor.frameCount, entry.frameCount)
            XCTAssertFalse(track.poseRuns.isEmpty)
        }
    }

    private func descriptor(
        _ entry: MindEyeFillerFrameIndex.Entry,
        locator: MindEyeResourceLocator
    ) throws -> TuringFillerClipDescriptor {
        TuringFillerClipDescriptor(
            identity: .init(
                fillerID: entry.fillerID,
                speakerCharacterID: entry.speakerCharacterID,
                audioResourcePath: entry.audioResourcePath,
                audioSHA256: entry.audioSHA256,
                trackResourcePath: entry.trackResourcePath,
                trackSHA256: entry.trackSHA256
            ),
            fileURL: try locator.resolve(resourcePath: entry.audioResourcePath),
            weight: entry.weight,
            authoringMode: entry.authoringMode
        )
    }
}

import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredFrameRuntimeWorkerTests: XCTestCase {
    @MainActor
    func testProductionWorkerLoadsAndCompactsPublishedManifestOffMain() async throws {
        let worker = MindEyeSerialAuthoredFrameWorker(label: "phase8.test.worker")
        let locator = MindEyeResourceLocator(
            resourceRootURL: MindEyePhase8TestFixtures.sourceResourceRoot
        )
        let snapshot = try await worker.loadIndex(locator: locator)
        XCTAssertEqual(snapshot.index.entries.count, 37)
        let entry = try XCTUnwrap(snapshot.index.entries.first)
        let track = try await worker.loadTrack(indexEntry: entry, locator: locator)
        XCTAssertEqual(track.descriptor.prID, entry.prID)
        XCTAssertEqual(track.compactPoseByteCount, entry.frameCount)
        XCTAssertFalse(track.poseRuns.isEmpty)
    }
}

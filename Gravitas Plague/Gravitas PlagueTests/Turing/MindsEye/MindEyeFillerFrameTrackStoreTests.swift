import XCTest

@testable import Gravitas_Plague

final class MindEyeFillerFrameTrackStoreTests: XCTestCase {
    private actor CountingWorker: MindEyeFillerFrameWorking {
        let base = MindEyeSerialFillerFrameWorker()
        private var indexLoads = 0
        private var trackLoads = 0

        func loadIndex(
            locator: MindEyeResourceLocator
        ) async throws -> MindEyeFillerFrameIndexSnapshot {
            indexLoads += 1
            try await Task.sleep(for: .milliseconds(20))
            return try await base.loadIndex(locator: locator)
        }

        func loadTrack(
            entry: MindEyeFillerFrameIndex.Entry,
            clip: TuringFillerClipDescriptor,
            expectedSurface: StoryInteractionSurfaceID,
            locator: MindEyeResourceLocator
        ) async throws -> MindEyeAuthoredFrameTrack {
            trackLoads += 1
            try await Task.sleep(for: .milliseconds(20))
            return try await base.loadTrack(
                entry: entry,
                clip: clip,
                expectedSurface: expectedSurface,
                locator: locator
            )
        }

        func counts() -> (index: Int, track: Int) { (indexLoads, trackLoads) }
    }

    func testIndexPrewarmAndConcurrentAcquireCoalesce() async throws {
        let locator = MindEyeResourceLocator(
            resourceRootURL: MindEyePhase8TestFixtures.sourceResourceRoot
        )
        let worker = CountingWorker()
        let store = MindEyeFillerFrameTrackStore(locator: locator, worker: worker)
        async let firstIndex = store.prepareIndex()
        async let secondIndex = store.prepareIndex()
        let snapshots = await [firstIndex, secondIndex]
        let snapshot = try snapshots[0].get()
        XCTAssertEqual(try snapshots[1].get(), snapshot)
        let indexCounts = await worker.counts()
        XCTAssertEqual(indexCounts.index, 1)

        let entry = try XCTUnwrap(snapshot.entriesByFillerID.values.first)
        let clip = try descriptor(entry, locator: locator)
        async let prewarm: Void = store.prewarm(
            clip: clip,
            expectedSurface: .walkie,
            reason: "test.prewarm"
        )
        async let first = store.acquire(
            clip: clip,
            expectedSurface: .walkie,
            reason: "test.first"
        )
        async let second = store.acquire(
            clip: clip,
            expectedSurface: .walkie,
            reason: "test.second"
        )
        _ = await prewarm
        let acquisitions = await [first, second]
        var leases: [MindEyeFillerFrameTrackLease] = []
        for acquisition in acquisitions {
            guard case .ready(let lease, let track) = acquisition else {
                return XCTFail("Coalesced filler acquisition failed")
            }
            XCTAssertEqual(track.descriptor.prID, entry.fillerID)
            leases.append(lease)
        }
        let trackCounts = await worker.counts()
        XCTAssertEqual(trackCounts.track, 1)
        XCTAssertEqual(Set(leases.map(\.id)).count, 2)
        let loadedSnapshot = await store.snapshot()
        XCTAssertLessThanOrEqual(loadedSnapshot.compactByteCount, 512 * 1024)

        for lease in leases { await store.release(lease, reason: "test.cleanup") }
        await store.evictInactive(reason: "test.cleanup")
        let finalSnapshot = await store.snapshot()
        XCTAssertTrue(finalSnapshot.cachedFillerIDs.isEmpty)
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

import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredFrameTrackStoreTests: XCTestCase {
    private actor CountingWorker: MindEyeAuthoredFrameWorking {
        let base: MindEyeSerialAuthoredFrameWorker
        private(set) var indexLoadCount = 0
        private(set) var trackLoadCount = 0

        init(label: String) {
            base = MindEyeSerialAuthoredFrameWorker(label: label)
        }

        func loadIndex(
            locator: MindEyeResourceLocator
        ) async throws -> MindEyeAuthoredFrameIndexSnapshot {
            indexLoadCount += 1
            try await Task.sleep(for: .milliseconds(20))
            return try await base.loadIndex(locator: locator)
        }

        func loadTrack(
            indexEntry: MindEyeAuthoredFrameIndex.Entry,
            locator: MindEyeResourceLocator
        ) async throws -> MindEyeAuthoredFrameTrack {
            trackLoadCount += 1
            try await Task.sleep(for: .milliseconds(20))
            return try await base.loadTrack(indexEntry: indexEntry, locator: locator)
        }

        func counts() -> (index: Int, track: Int) {
            (indexLoadCount, trackLoadCount)
        }
    }

    func testAll37TracksLoadSequentiallyAndCacheNeverExceedsTwo() async throws {
        let locator = MindEyeResourceLocator(
            resourceRootURL: MindEyePhase8TestFixtures.sourceResourceRoot
        )
        let worker = MindEyeSerialAuthoredFrameWorker(label: "phase8.test.store")
        let snapshot = try await worker.loadIndex(locator: locator)
        let store = MindEyeAuthoredFrameTrackStore(
            locator: locator,
            worker: worker,
            maximumResidentTracks: 2
        )
        for entry in snapshot.index.entries {
            let acquisition = await store.acquire(
                prID: entry.prID,
                expectedSpeaker: entry.speakerCharacterID,
                expectedSurface: entry.interactionSurface,
                reason: "all37"
            )
            guard case .ready(let lease, let track) = acquisition else {
                return XCTFail("Track did not load: \(entry.prID)")
            }
            XCTAssertEqual(track.descriptor.prID, entry.prID)
            await store.release(lease, reason: "all37")
            let cacheCount = await store.snapshot().cachedPRIDs.count
            XCTAssertLessThanOrEqual(cacheCount, 2)
        }
    }

    func testIndexAndSamePRTrackLoadsCoalesce() async throws {
        let locator = MindEyeResourceLocator(
            resourceRootURL: MindEyePhase8TestFixtures.sourceResourceRoot
        )
        let worker = CountingWorker(label: "phase8.test.store.coalescing")
        let store = MindEyeAuthoredFrameTrackStore(
            locator: locator,
            worker: worker,
            maximumResidentTracks: 2
        )
        async let firstIndex = store.prepareIndex()
        async let secondIndex = store.prepareIndex()
        let indexResults = await [firstIndex, secondIndex]
        let snapshot = try indexResults[0].get()
        XCTAssertEqual(try indexResults[1].get(), snapshot)
        var counts = await worker.counts()
        XCTAssertEqual(counts.index, 1)

        let entry = try XCTUnwrap(snapshot.index.entries.first)
        async let first = store.acquire(
            prID: entry.prID,
            expectedSpeaker: entry.speakerCharacterID,
            expectedSurface: entry.interactionSurface,
            reason: "coalescing.first"
        )
        async let second = store.acquire(
            prID: entry.prID,
            expectedSpeaker: entry.speakerCharacterID,
            expectedSurface: entry.interactionSurface,
            reason: "coalescing.second"
        )
        let acquisitions = await [first, second]
        var leases: [MindEyeAuthoredFrameTrackLease] = []
        for acquisition in acquisitions {
            guard case .ready(let lease, let track) = acquisition else {
                return XCTFail("Coalesced acquisition failed")
            }
            XCTAssertEqual(track.descriptor.prID, entry.prID)
            leases.append(lease)
        }
        counts = await worker.counts()
        XCTAssertEqual(counts.track, 1)
        XCTAssertEqual(Set(leases.map(\.id)).count, 2)
        for lease in leases { await store.release(lease, reason: "coalescing") }
    }

    func testTwoPinnedTracksRejectThirdThenLRUEvictsOnlyInactiveTrack() async throws {
        let locator = MindEyeResourceLocator(
            resourceRootURL: MindEyePhase8TestFixtures.sourceResourceRoot
        )
        let worker = MindEyeSerialAuthoredFrameWorker(label: "phase8.test.store.conflict")
        let index = try await worker.loadIndex(locator: locator)
        let entries = Array(index.index.entries.prefix(3))
        XCTAssertEqual(entries.count, 3)
        let store = MindEyeAuthoredFrameTrackStore(
            locator: locator,
            worker: worker,
            maximumResidentTracks: 2
        )
        var leases: [MindEyeAuthoredFrameTrackLease] = []
        for entry in entries.prefix(2) {
            let acquisition = await store.acquire(
                prID: entry.prID,
                expectedSpeaker: entry.speakerCharacterID,
                expectedSurface: entry.interactionSurface,
                reason: "pin"
            )
            guard case .ready(let lease, _) = acquisition else {
                return XCTFail("Could not pin \(entry.prID)")
            }
            leases.append(lease)
        }
        let third = await store.acquire(
            prID: entries[2].prID,
            expectedSpeaker: entries[2].speakerCharacterID,
            expectedSurface: entries[2].interactionSurface,
            reason: "thirdConflict"
        )
        guard case .unavailable(let failure) = third else {
            return XCTFail("Third pinned track should remain rest-mouth")
        }
        XCTAssertEqual(failure.code, .authoredFrameTrackCacheConflict)
        let pinnedSnapshot = await store.snapshot()
        XCTAssertEqual(pinnedSnapshot.cachedPRIDs.count, 2)

        await store.release(leases[0], reason: "makeInactive")
        let replacement = await store.acquire(
            prID: entries[2].prID,
            expectedSpeaker: entries[2].speakerCharacterID,
            expectedSurface: entries[2].interactionSurface,
            reason: "replaceInactive"
        )
        guard case .ready(let replacementLease, _) = replacement else {
            return XCTFail("Inactive LRU track was not replaceable")
        }
        let cached = await store.snapshot().cachedPRIDs
        XCTAssertEqual(cached.count, 2)
        XCTAssertFalse(cached.contains(entries[0].prID))
        XCTAssertTrue(cached.contains(entries[1].prID))
        XCTAssertTrue(cached.contains(entries[2].prID))

        await store.release(leases[0], reason: "staleRelease")
        let afterStaleRelease = await store.snapshot()
        XCTAssertEqual(afterStaleRelease.cachedPRIDs.count, 2)
        await store.release(leases[1], reason: "cleanup")
        await store.release(replacementLease, reason: "cleanup")
        await store.evictInactive(reason: "cleanup")
        let final = await store.snapshot()
        XCTAssertTrue(final.cachedPRIDs.isEmpty)
        XCTAssertTrue(final.leasedPRIDs.isEmpty)
        XCTAssertTrue(final.loadingPRIDs.isEmpty)
    }

    func testPrewarmMissThenHitLeavesOneInactiveCompactTrack() async throws {
        let locator = MindEyeResourceLocator(
            resourceRootURL: MindEyePhase8TestFixtures.sourceResourceRoot
        )
        let worker = CountingWorker(label: "phase8.test.store.prewarm")
        let store = MindEyeAuthoredFrameTrackStore(
            locator: locator,
            worker: worker,
            maximumResidentTracks: 2
        )
        let snapshot = try await store.prepareIndex().get()
        let entry = try XCTUnwrap(snapshot.index.entries.first)
        let miss = await store.prewarm(
            prID: entry.prID,
            expectedSpeaker: entry.speakerCharacterID,
            expectedSurface: entry.interactionSurface,
            reason: "miss"
        )
        _ = try miss.get()
        let hit = await store.prewarm(
            prID: entry.prID,
            expectedSpeaker: entry.speakerCharacterID,
            expectedSurface: entry.interactionSurface,
            reason: "hit"
        )
        _ = try hit.get()
        let counts = await worker.counts()
        XCTAssertEqual(counts.track, 1)
        let state = await store.snapshot()
        XCTAssertEqual(state.cachedPRIDs, [entry.prID])
        XCTAssertTrue(state.leasedPRIDs.isEmpty)
    }
}

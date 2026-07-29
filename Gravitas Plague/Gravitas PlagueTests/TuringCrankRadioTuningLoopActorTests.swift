import Foundation
import XCTest

@testable import Gravitas_Plague

@MainActor
final class TuringCrankRadioTuningLoopActorTests: XCTestCase {
    func testExactFourAuthoredResourcesValidate() async throws {
        let actor = TuringCrankRadioTuningLoopActor(
            randomIndex: { _ in 0 }
        )

        try await actor.prepareResources()
        let resources = await actor.preparedResources()

        XCTAssertEqual(
            resources.map(\.fileName),
            [
                "crank-radio-tuning-01.mp3",
                "crank-radio-tuning-02.mp3",
                "crank-radio-tuning-03.mp3",
                "crank-radio-tuning-04.mp3"
            ]
        )
        for resource in resources {
            XCTAssertGreaterThan(resource.durationSeconds, 0)
            XCTAssertGreaterThan(resource.sampleRate, 0)
            XCTAssertGreaterThan(resource.channelCount, 0)
            XCTAssertGreaterThan(resource.byteCount, 0)
            XCTAssertEqual(resource.sha256.count, 64)
        }
    }

    func testSameGapIsIdempotentAndNewGapAvoidsImmediateRepeat()
        async throws
    {
        let actor = TuringCrankRadioTuningLoopActor(
            randomIndex: { _ in 0 }
        )
        let endpoint = CrankRadioTuningTestEndpoint()
        try await actor.prepareResources()
        await actor.install(endpoint: endpoint)

        await actor.beginGap(
            ownerID: "owner",
            waitingForSegmentIndex: 0,
            reason: "first"
        )
        await actor.beginGap(
            ownerID: "owner",
            waitingForSegmentIndex: 0,
            reason: "sameGap"
        )

        var snapshot = await endpoint.snapshot()
        XCTAssertEqual(snapshot.played.count, 1)
        XCTAssertEqual(
            snapshot.played.first?.kind,
            .crankRadioTuningFiller
        )
        XCTAssertEqual(
            snapshot.played.first?.route,
            .rollingBenchRadio
        )
        XCTAssertEqual(
            snapshot.played.first?.cachePolicy,
            .transient
        )
        XCTAssertEqual(
            snapshot.played.first?.shouldLoop,
            true
        )

        let firstFile =
            snapshot.played[0].fileURL.lastPathComponent
        await actor.endGap(
            ownerID: "owner",
            reason: "segmentZeroReady"
        )
        snapshot = await endpoint.snapshot()
        XCTAssertEqual(snapshot.stopped.count, 1)
        XCTAssertEqual(
            snapshot.evicted.map(\.lastPathComponent),
            [firstFile]
        )

        await actor.beginGap(
            ownerID: "owner",
            waitingForSegmentIndex: 2,
            reason: "laterGap"
        )
        snapshot = await endpoint.snapshot()
        XCTAssertEqual(snapshot.played.count, 2)
        XCTAssertNotEqual(
            snapshot.played[1].fileURL.lastPathComponent,
            firstFile
        )

        await actor.reset(reason: "testFinished")
    }

    func testStaleOwnerCannotStopCurrentLoop() async throws {
        let actor = TuringCrankRadioTuningLoopActor(
            randomIndex: { _ in 0 }
        )
        let endpoint = CrankRadioTuningTestEndpoint()
        try await actor.prepareResources()
        await actor.install(endpoint: endpoint)

        await actor.beginGap(
            ownerID: "ownerA",
            waitingForSegmentIndex: 0,
            reason: "ownerA"
        )
        await actor.endGap(
            ownerID: "ownerA",
            reason: "ownerAFinished"
        )
        await actor.beginGap(
            ownerID: "ownerB",
            waitingForSegmentIndex: 0,
            reason: "ownerB"
        )
        await actor.endGap(
            ownerID: "ownerA",
            reason: "staleOwnerAEnd"
        )

        let snapshot = await endpoint.snapshot()
        let activeFileName = await actor.activeFileName()
        XCTAssertEqual(snapshot.played.count, 2)
        XCTAssertEqual(snapshot.stopped.count, 1)
        XCTAssertNotNil(activeFileName)

        await actor.reset(reason: "testFinished")
    }
}

private actor CrankRadioTuningTestEndpoint:
    TuringTransientAudioPlaybackEndpoint
{
    struct Snapshot: Sendable {
        let played: [TuringAudioPlaybackRequest]
        let stopped: [TuringAudioPlaybackHandle]
        let evicted: [URL]
    }

    private let eventHub = TuringAudioEventHub()
    private var played: [TuringAudioPlaybackRequest] = []
    private var stopped: [TuringAudioPlaybackHandle] = []
    private var evicted: [URL] = []

    func play(
        _ request: TuringAudioPlaybackRequest
    ) async throws -> TuringAudioPlaybackHandle {
        played.append(request)
        let handle = TuringAudioPlaybackHandle(
            id: UUID(),
            requestID: request.requestID,
            runID: request.runID,
            route: request.route
        )
        await eventHub.yield(.started(handle))
        return handle
    }

    func stop(
        _ handle: TuringAudioPlaybackHandle,
        reason: String
    ) async {
        stopped.append(handle)
        await eventHub.yield(
            .cancelled(handle, reason: reason)
        )
    }

    func events() async -> AsyncStream<TuringAudioPlaybackEvent> {
        await eventHub.stream()
    }

    func evictTransient(fileURL: URL) async {
        evicted.append(fileURL)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            played: played,
            stopped: stopped,
            evicted: evicted
        )
    }
}
